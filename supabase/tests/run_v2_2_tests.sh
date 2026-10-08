#!/usr/bin/env bash
# v2.2 save-safety test runner (per-game migrations). LOCAL THROWAWAY POSTGRES ONLY (unix socket, no TCP, trust auth,
# no secrets). Never point this at supabase.teserix.com or any remote database: it drops/creates databases.
#   bash supabase/tests/run_v2_2_tests.sh 2>&1 | tee supabase/tests/results/v2_2_test_run.log     (*.log is gitignored)
# Needs PostgreSQL 17 binaries (Debian: apt install postgresql postgresql-17-cron). pg_cron optional (O2-O4 need it).
# Modes:
#   (a) each game alone: a database with ONLY that game's pre-v2.2 base (no object of the other game): migrate x2,
#       game tests, ops file without pg_cron, rollback guard, rollback, pg_dump schema compare; plus a clean
#       migrate -> rollback x2 round trip with schema + data compare.
#   (b) both in the shared pre-v2.2 schema (today's live layout), in both orders: idempotency (x2, both orders), game
#       tests + shared checks, per-game ops files with pg_cron, each rollback touching only its own game, pg_dump compare.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
PGBIN="${PGBIN:-/usr/lib/postgresql/17/bin}"
SOCK="${V22_SOCK:-/tmp}"; PORT="${V22_PORT:-55432}"; DATA="${V22_DATA:-/tmp/pgv22}"
MIG_K="$ROOT/migrations/20260928160000_v2_2_kodhane_save_safety.sql"
MIG_A="$ROOT/migrations/20260928160100_v2_2_acik_ofis_save_safety.sql"
RB_K="$ROOT/rollback/20260928160000_v2_2_kodhane_save_safety.rollback.sql"
RB_A="$ROOT/rollback/20260928160100_v2_2_acik_ofis_save_safety.rollback.sql"
OPS_K="$ROOT/ops/20260928160000_v2_2_kodhane_schedule_cleanup.sql"
OPS_A="$ROOT/ops/20260928160100_v2_2_acik_ofis_schedule_cleanup.sql"
FIX="$HERE/fixtures"; OUT="${V22_OUT:-/tmp/v22-test}"; mkdir -p "$OUT"; RES="$OUT/results.tsv"; : > "$RES"
KC="${KODHANE_CLOUD:-/workspace/kodhane-cloud}"
CRONDB=v22_shared
[[ "$SOCK" == /* ]] || { echo "refusing: V22_SOCK must be a local socket directory"; exit 2; }
unset PGHOST PGHOSTADDR PGPORT PGUSER PGPASSWORD PGDATABASE PGSERVICE PGSERVICEFILE DATABASE_URL SUPABASE_DB_URL || true

start_cluster() {
  rm -rf "$DATA"; "$PGBIN/initdb" -D "$DATA" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
  printf "port = %s\nlisten_addresses = ''\nunix_socket_directories = '%s'\ntimezone = 'UTC'\n" "$PORT" "$SOCK" >> "$DATA/postgresql.conf"
  if [[ -f /usr/lib/postgresql/17/lib/pg_cron.so ]]; then
    printf "shared_preload_libraries = 'pg_cron'\ncron.database_name = '%s'\n" "$CRONDB" >> "$DATA/postgresql.conf"
  fi
  "$PGBIN/pg_ctl" -D "$DATA" -l "$DATA.log" start -w >/dev/null
}
if ! "$PGBIN/pg_isready" -q -h "$SOCK" -p "$PORT"; then
  echo "== starting throwaway cluster $DATA (socket $SOCK:$PORT, no TCP)"; start_cluster
elif [[ -f /usr/lib/postgresql/17/lib/pg_cron.so && "$("$PGBIN/psql" -h "$SOCK" -p "$PORT" -U postgres -XAtc "select current_setting('cron.database_name', true)")" != "$CRONDB" ]]; then
  echo "== restarting throwaway cluster $DATA (cron.database_name -> $CRONDB)"
  "$PGBIN/pg_ctl" -D "$DATA" stop -m fast >/dev/null; start_cluster
fi
psql_() { "$PGBIN/psql" -h "$SOCK" -p "$PORT" -U postgres -X -v ON_ERROR_STOP=1 -q "$@"; }
dump_schema() { "$PGBIN/pg_dump" -h "$SOCK" -p "$PORT" -U postgres --schema-only -n public -n auth "$1" | grep -v -E '^(--|\\restrict|\\unrestrict)' | sed '/^$/d'; }
dump_data()   { "$PGBIN/pg_dump" -h "$SOCK" -p "$PORT" -U postgres --data-only -n public -n auth "$1" | grep -v -E '^(--|\\restrict|\\unrestrict|SET |SELECT pg_catalog)' | sed '/^$/d' | sort; }
# one game's objects: its tables (schema + data, incl. triggers/policies/grants) + its functions (definition + ACL)
dump_game() { "$PGBIN/pg_dump" -h "$SOCK" -p "$PORT" -U postgres -t "public.$2_*" "$1" | grep -v -E '^(--|\\restrict|\\unrestrict)' | sed '/^$/d';
              psql_ -d "$1" -Atc "select p.oid::regprocedure || ' ' || md5(pg_get_functiondef(p.oid)) || ' ' || coalesce(p.proacl::text, '') || ' ' || coalesce(obj_description(p.oid, 'pg_proc'), '')
                                  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like '$2\_%' order by 1"; }
res() {  # name pass [info]
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$RES"; [[ "$2" == true ]] && echo "PASS $1" || echo "FAIL $1 ${3:-}"; }
collect() {  # copy t.results of a database into the global result file (prefixed)
  psql_ -d "$1" -AtF $'\t' -c "select '$2' || name, pass, coalesce(info, '') from t.results order by n" >> "$RES"
  psql_ -d "$1" -AtF $'\t' -c "select '$2' || name, pass, coalesce(info, '') from t.results where not pass order by n" | sed 's/^/FAIL /' || true
  echo "   $2: $(psql_ -d "$1" -Atc "select count(*) filter (where pass) || '/' || count(*) from t.results")"; }
fresh_db() {  # db base-fixtures... (then helpers + seeds by the caller's list)
  local db=$1; shift
  "$PGBIN/dropdb" -h "$SOCK" -p "$PORT" -U postgres --if-exists --force "$db" 2>/dev/null
  "$PGBIN/createdb" -h "$SOCK" -p "$PORT" -U postgres "$db"
  psql_ -d "$db" -f "$FIX/stub_supabase.sql"
  for f in "$@"; do
    case "$f" in pre_*) psql_ -d "$db" -f "$FIX/$f" >/dev/null 2>&1 ;; *) psql_ -d "$db" -f "$FIX/$f" ;; esac
  done
}
mig() { psql_ -d "$1" -f "$2" 2>&1 | grep -E 'ERROR|cron' || true; }
run_tests() { psql_ -d "$1" -f "$2" 2>&1 | grep -E '^psql:.*ERROR' | sed -E 's/^psql:[^:]+:[0-9]+: //' || true; }
rollback_guard() {  # db rb setting label
  local o; if o=$(PGOPTIONS='' psql_ -d "$1" -f "$2" 2>&1); then res "$4 rollback without $3 refused" false "it ran"
  else grep -q "set $3 = 'on'" <<<"$o" && res "$4 rollback refuses to drop backups without $3" true || res "$4 rollback guard" false "$o"; fi; }
rollback() { PGOPTIONS="-c $3=on" psql_ -d "$1" -f "$2" 2>&1 | grep -E 'ERROR|FATAL|error:' || true; }
cmp_res() {  # label fileA fileB
  if diff -u "$2" "$3" > "$2.diff"; then res "$1" true; else res "$1" false "see $2.diff"; fi; }
K_BASE="pre_v2_2_kodhane_only.sql helpers.sql seed_kodhane.sql"
A_BASE="pre_v2_2_acik_ofis_only.sql helpers.sql seed_acik_ofis.sql"
S_BASE="pre_v2_2_schema.sql helpers.sql seed_kodhane.sql seed_acik_ofis.sql"
"$PGBIN/psql" -h "$SOCK" -p "$PORT" -U postgres -XAtc "select 'server: ' || version()"

# ============================================================== (a) each game alone
standalone() {  # tag game mig rb ops test base-list  (other game's prefix = $7)
  local tag=$1 g=$2 m=$3 rb=$4 ops=$5 tst=$6 other=$7; shift 7; local db="v22_${g}_only"
  echo "== (a) $g alone (db $db: only the $g pre-v2.2 base)"
  fresh_db "$db" "$@"
  [[ "$(psql_ -d "$db" -Atc "select count(*) from pg_class where relnamespace = 'public'::regnamespace and relname like '${other}\_%'")" == 0 ]] \
    && res "$tag-M0 base has no object of the other game ($other)" true || res "$tag-M0 other game objects present" false
  dump_schema "$db" > "$OUT/$db.schema.before"
  mig "$db" "$m"; mig "$db" "$m"
  res "$tag-M1 migration applied twice (idempotent) on the $g-only base" true
  run_tests "$db" "$tst"
  local o; o=$(psql_ -d "$db" -f "$ops" 2>&1) && grep -q "pg_cron is not enabled" <<<"$o" \
    && res "$tag-O1 ops file without pg_cron: NOTICE + exit 0" true || res "$tag-O1 ops file without pg_cron" false "$o"
  [[ "$(psql_ -d "$db" -Atc "select count(*) from pg_class where relnamespace = 'public'::regnamespace and relname like '${other}\_%'")" == 0 ]] \
    && res "$tag-M2 migration created no object of the other game" true || res "$tag-M2 other game objects created" false
  collect "$db" "$tag|"
  rollback_guard "$db" "$rb" "v22.${g}_allow_backup_loss" "$tag-R0"
  rollback "$db" "$rb" "v22.${g}_allow_backup_loss"
  dump_schema "$db" > "$OUT/$db.schema.after"
  cmp_res "$tag-R1 used db: schema after rollback == pre-migration schema (pg_dump public+auth)" "$OUT/$db.schema.before" "$OUT/$db.schema.after"
  # clean round trip: schema + data
  fresh_db "${db}_rt" "$@"
  dump_schema "${db}_rt" > "$OUT/${db}_rt.schema.before"; dump_data "${db}_rt" > "$OUT/${db}_rt.data.before"
  mig "${db}_rt" "$m"; rollback "${db}_rt" "$rb" "v22.${g}_allow_backup_loss"; rollback "${db}_rt" "$rb" "v22.${g}_allow_backup_loss"
  dump_schema "${db}_rt" > "$OUT/${db}_rt.schema.after"; dump_data "${db}_rt" > "$OUT/${db}_rt.data.after"
  cmp_res "$tag-R2 clean migrate -> rollback x2: schema identical" "$OUT/${db}_rt.schema.before" "$OUT/${db}_rt.schema.after"
  cmp_res "$tag-R3 clean migrate -> rollback x2: all public/auth data identical" "$OUT/${db}_rt.data.before" "$OUT/${db}_rt.data.after"
}
standalone a-K kodhane "$MIG_K" "$RB_K" "$OPS_K" "$HERE/v2_2_kodhane.test.sql" acik_ofis $K_BASE
standalone a-AO acik_ofis "$MIG_A" "$RB_A" "$OPS_A" "$HERE/v2_2_acik_ofis.test.sql" kodhane $A_BASE

# ============================================================== (b) both in the shared schema, both orders
cronjob() { psql_ -d "$1" -Atc "select coalesce(string_agg(jobid || '|' || schedule || '|' || command || '|' || active, ';' order by jobid), '') from cron.job where jobname = '$2'"; }
shared() {  # tag first-game second-game
  local tag=$1 first=$2 second=$3 db=$CRONDB
  local mf ms; [[ $first == kodhane ]] && { mf=$MIG_K; ms=$MIG_A; } || { mf=$MIG_A; ms=$MIG_K; }
  echo "== (b) shared schema, order $first -> $second (db $db)"
  fresh_db "$db" $S_BASE
  dump_schema "$db" > "$OUT/$tag.schema.before"
  mig "$db" "$mf"; dump_schema "$db" > "$OUT/$tag.schema.one"
  mig "$db" "$ms"; dump_schema "$db" > "$OUT/$tag.schema.both"
  mig "$db" "$ms"; mig "$db" "$mf"; dump_schema "$db" > "$OUT/$tag.schema.both2"
  cmp_res "$tag-M1 both applied, then again in the reverse order: schema unchanged (idempotent, no name clash)" "$OUT/$tag.schema.both" "$OUT/$tag.schema.both2"
  if [[ $first == kodhane ]]; then
    run_tests "$db" "$HERE/v2_2_kodhane.test.sql"; run_tests "$db" "$HERE/v2_2_acik_ofis.test.sql"
  else
    run_tests "$db" "$HERE/v2_2_acik_ofis.test.sql"; run_tests "$db" "$HERE/v2_2_kodhane.test.sql"
  fi
  run_tests "$db" "$HERE/v2_2_shared.test.sql"
  mig "$db" "$MIG_A"   # re-mirror nicknames (kodhane_profiles is the master until the split)
  [[ "$(psql_ -d "$db" -Atc "select nickname from public.acik_ofis_profiles where user_id = '22222222-2222-4222-8222-222222222222'")" == "Oyuncu Yeni" ]] \
    && res "$tag-M3 re-running the Açık Ofis migration re-mirrors changed nicknames into acik_ofis_profiles" true || res "$tag-M3 re-mirror" false
  collect "$db" "$tag|"
  # KC leaderboard.sql v6 re-run must not bring v5 back
  if [[ -f "$KC/leaderboard.sql" ]]; then
    local lo; lo=$(psql_ -d "$db" -f "$KC/leaderboard.sql" 2>&1) || true
    [[ "$(psql_ -d "$db" -Atc "select obj_description('public.kodhane_leaderboard(integer,text)'::regprocedure, 'pg_proc') like '%v6 (Kodhane v2.2 migration 20260928160000)%'")" == t ]] && grep -q "v6 (from the Kodhane v2.2 migration) is live" <<<"$lo" \
      && res "$tag-L1 re-running kodhane-cloud/leaderboard.sql (v6) keeps kodhane_leaderboard v6" true || res "$tag-L1 leaderboard.sql re-run" false "$lo"
  fi
  # ops files (pg_cron) — per game, independent
  local o; o=$(psql_ -d "$db" -f "$OPS_K" 2>&1; psql_ -d "$db" -f "$OPS_A" 2>&1) && [[ $(grep -c "pg_cron is not enabled" <<<"$o") == 2 ]] \
    && res "$tag-O1 both ops files without pg_cron enabled: NOTICE + exit 0" true || res "$tag-O1 ops without pg_cron" false "$o"
  if psql_ -d "$db" -c "create extension if not exists pg_cron" 2>/dev/null; then   # simulates the admin enabling pg_cron
    psql_ -d "$db" -f "$OPS_K" >/dev/null 2>&1; psql_ -d "$db" -f "$OPS_A" >/dev/null 2>&1
    local jk ja; jk=$(cronjob "$db" kodhane_save_backups_cleanup); ja=$(cronjob "$db" acik_ofis_save_backups_cleanup)
    [[ "$jk" =~ ^[0-9]+\|17\ 0\ \*\ \*\ \*\|select\ public\.kodhane_cleanup_save_backups\(\)\|true$ && "$ja" =~ ^[0-9]+\|17\ 0\ \*\ \*\ \*\|select\ public\.acik_ofis_cleanup_save_backups\(\)\|true$ ]] \
      && res "$tag-O2 each ops file schedules its own job (17 0 * * * UTC)" true "$jk / $ja" || res "$tag-O2 ops schedule" false "$jk / $ja"
    psql_ -d "$db" -f "$OPS_K" >/dev/null 2>&1; psql_ -d "$db" -f "$OPS_A" >/dev/null 2>&1
    [[ "$(cronjob "$db" kodhane_save_backups_cleanup)" == "$jk" && "$(cronjob "$db" acik_ofis_save_backups_cleanup)" == "$ja" ]] \
      && res "$tag-O3 ops files run twice: still exactly one identical job each" true || res "$tag-O3 ops idempotent" false
    psql_ -d "$db" -c "select cron.alter_job((select jobid from cron.job where jobname='kodhane_save_backups_cleanup'), schedule := '0 5 * * *', active := false)" >/dev/null
    psql_ -d "$db" -f "$OPS_K" >/dev/null 2>&1
    [[ "$(cronjob "$db" kodhane_save_backups_cleanup)" == "$jk" && "$(cronjob "$db" acik_ofis_save_backups_cleanup)" == "$ja" ]] \
      && res "$tag-O4 drifted job repaired in place (same jobid), the other game's job untouched" true || res "$tag-O4 ops repair" false
  else res "$tag-O2-O4 skipped: pg_cron not installed on this server" true; fi
  # rollbacks: second game first, then first game; each must leave the other game's objects byte-identical
  local g1=$first g2=$second rb1 rb2; [[ $first == kodhane ]] && { rb1=$RB_K; rb2=$RB_A; } || { rb1=$RB_A; rb2=$RB_K; }
  rollback_guard "$db" "$rb2" "v22.${g2}_allow_backup_loss" "$tag-R0-$g2"
  dump_game "$db" "$g1" > "$OUT/$tag.$g1.before_rb_$g2"
  rollback "$db" "$rb2" "v22.${g2}_allow_backup_loss"
  dump_game "$db" "$g1" > "$OUT/$tag.$g1.after_rb_$g2"
  cmp_res "$tag-R1 rollback of $g2 leaves every $g1 table (schema + data) and function byte-identical" "$OUT/$tag.$g1.before_rb_$g2" "$OUT/$tag.$g1.after_rb_$g2"
  [[ "$(psql_ -d "$db" -Atc "select count(*) from cron.job where jobname = '${g2}_save_backups_cleanup'" 2>/dev/null || echo 0)" == 0 && "$(psql_ -d "$db" -Atc "select count(*) from cron.job where jobname = '${g1}_save_backups_cleanup'" 2>/dev/null || echo 1)" == 1 ]] \
    && res "$tag-R2 rollback of $g2 unscheduled only its own pg_cron job" true || res "$tag-R2 cron after rollback" false
  rollback_guard "$db" "$rb1" "v22.${g1}_allow_backup_loss" "$tag-R3-$g1"
  rollback "$db" "$rb1" "v22.${g1}_allow_backup_loss"
  psql_ -d "$db" -c "drop extension if exists pg_cron" >/dev/null
  dump_schema "$db" > "$OUT/$tag.schema.after"
  cmp_res "$tag-R4 used db: both rolled back -> schema == pre-migration schema (pg_dump public+auth)" "$OUT/$tag.schema.before" "$OUT/$tag.schema.after"
  # clean round trip in this order: one rollback restores exactly the one-migration state, then the original (schema + data)
  fresh_db "${db}_rt" $S_BASE
  dump_schema "${db}_rt" > "$OUT/$tag.rt.schema.before"; dump_data "${db}_rt" > "$OUT/$tag.rt.data.before"
  mig "${db}_rt" "$mf"; dump_schema "${db}_rt" > "$OUT/$tag.rt.schema.one"; mig "${db}_rt" "$ms"
  rollback "${db}_rt" "$rb2" "v22.${g2}_allow_backup_loss"; dump_schema "${db}_rt" > "$OUT/$tag.rt.schema.one_after"
  cmp_res "$tag-R5 clean: rollback of $g2 returns exactly to the $g1-only state (schema)" "$OUT/$tag.rt.schema.one" "$OUT/$tag.rt.schema.one_after"
  rollback "${db}_rt" "$rb1" "v22.${g1}_allow_backup_loss"; rollback "${db}_rt" "$rb1" "v22.${g1}_allow_backup_loss"; rollback "${db}_rt" "$rb2" "v22.${g2}_allow_backup_loss"
  dump_schema "${db}_rt" > "$OUT/$tag.rt.schema.after"; dump_data "${db}_rt" > "$OUT/$tag.rt.data.after"
  cmp_res "$tag-R6 clean: both rolled back (x2): schema identical to before" "$OUT/$tag.rt.schema.before" "$OUT/$tag.rt.schema.after"
  cmp_res "$tag-R7 clean: both rolled back: all public/auth data identical to before" "$OUT/$tag.rt.data.before" "$OUT/$tag.rt.data.after"
  "$PGBIN/dropdb" -h "$SOCK" -p "$PORT" -U postgres --if-exists --force "${db}_rt"
}
shared b1 kodhane acik_ofis
shared b2 acik_ofis kodhane

# ============================================================== (b0) shared DB, ONLY the Açık Ofis file (today's supabase.teserix.com)
lb_k() {  # db -> Kodhane list as anon, u1, u2 (auth.uid() via the test helpers)
  psql_ -d "$1" -At <<'SQL'
select 'anon', * from (select t.login(null)) l, public.kodhane_leaderboard(50, 'kodhane');
select 'u1', * from (select t.login('11111111-1111-4111-8111-111111111111')) l, public.kodhane_leaderboard(50, 'kodhane');
select 'u2', * from (select t.login('22222222-2222-4222-8222-222222222222')) l, public.kodhane_leaderboard(3, 'kodhane');
SQL
}
shared_ao_only() {
  local tag=b0 db=v22_shared_ao
  echo "== (b0) shared schema, ONLY the Açık Ofis migration (Kodhane stays pre-v2.2, kodhane_leaderboard v5) (db $db)"
  fresh_db "$db" $S_BASE
  dump_schema "$db" > "$OUT/$tag.schema.before"; lb_k "$db" > "$OUT/$tag.lbk.before"
  local o; o=$(psql_ -d "$db" -f "$MIG_A" 2>&1) || true
  grep -q "shim installed" <<<"$o" && ! grep -q ERROR <<<"$o" && res "$tag-S1 Açık Ofis migration applied; NOTICE: kodhane_leaderboard shim installed" true || res "$tag-S1 apply" false "$o"
  dump_schema "$db" > "$OUT/$tag.schema.one"; lb_k "$db" > "$OUT/$tag.lbk.after"
  cmp_res "$tag-S2 Kodhane list (anon, u1, u2) byte-identical before/after the Açık Ofis migration" "$OUT/$tag.lbk.before" "$OUT/$tag.lbk.after"
  mig "$db" "$MIG_A"; dump_schema "$db" > "$OUT/$tag.schema.one2"
  cmp_res "$tag-S3 Açık Ofis migration twice (shim included): schema unchanged" "$OUT/$tag.schema.one" "$OUT/$tag.schema.one2"
  run_tests "$db" "$HERE/v2_2_acik_ofis.test.sql"
  run_tests "$db" "$HERE/v2_2_shared_ao_only.test.sql"
  collect "$db" "$tag|"
  rollback_guard "$db" "$RB_A" "v22.acik_ofis_allow_backup_loss" "$tag-R0"
  rollback "$db" "$RB_A" "v22.acik_ofis_allow_backup_loss"; rollback "$db" "$RB_A" "v22.acik_ofis_allow_backup_loss"
  dump_schema "$db" > "$OUT/$tag.schema.after"
  cmp_res "$tag-R1 Açık Ofis rollback (x2): schema == before, kodhane_leaderboard back to v5 exactly" "$OUT/$tag.schema.before" "$OUT/$tag.schema.after"
  # clean round trip: data too
  fresh_db "${db}_rt" $S_BASE; dump_data "${db}_rt" > "$OUT/$tag.rt.data.before"; dump_schema "${db}_rt" > "$OUT/$tag.rt.schema.before"
  mig "${db}_rt" "$MIG_A"; rollback "${db}_rt" "$RB_A" "v22.acik_ofis_allow_backup_loss"
  dump_data "${db}_rt" > "$OUT/$tag.rt.data.after"; dump_schema "${db}_rt" > "$OUT/$tag.rt.schema.after"
  cmp_res "$tag-R2 clean round trip: schema identical" "$OUT/$tag.rt.schema.before" "$OUT/$tag.rt.schema.after"
  cmp_res "$tag-R3 clean round trip: all public/auth data identical" "$OUT/$tag.rt.data.before" "$OUT/$tag.rt.data.after"
  # later on: Kodhane v2.2 on top (replaces the shim), Kodhane rollback brings the shim back, Açık Ofis rollback brings v5 back
  fresh_db "${db}_rt" $S_BASE; dump_schema "${db}_rt" > "$OUT/$tag.l.schema.before"
  mig "${db}_rt" "$MIG_A"; dump_schema "${db}_rt" > "$OUT/$tag.l.schema.ao"
  mig "${db}_rt" "$MIG_K"
  local c; c=$(psql_ -d "${db}_rt" -Atc "select obj_description('public.kodhane_leaderboard(integer,text)'::regprocedure, 'pg_proc') like '%v6 (Kodhane v2.2 migration 20260928160000)%'")
  mig "${db}_rt" "$MIG_A"   # re-run must not re-install the shim over v6
  [[ $c == t && "$(psql_ -d "${db}_rt" -Atc "select obj_description('public.kodhane_leaderboard(integer,text)'::regprocedure, 'pg_proc') like '%v6 (Kodhane v2.2 migration 20260928160000)%'")" == t ]] \
    && res "$tag-L1 Kodhane v2.2 applied later replaces the shim with v6; Açık Ofis re-run leaves v6" true || res "$tag-L1 shim -> v6" false
  rollback "${db}_rt" "$RB_K" "v22.kodhane_allow_backup_loss"; dump_schema "${db}_rt" > "$OUT/$tag.l.schema.ao2"
  cmp_res "$tag-L2 Kodhane rollback restores exactly the Açık Ofis-only state (shim back)" "$OUT/$tag.l.schema.ao" "$OUT/$tag.l.schema.ao2"
  rollback "${db}_rt" "$RB_A" "v22.acik_ofis_allow_backup_loss"; dump_schema "${db}_rt" > "$OUT/$tag.l.schema.after"
  cmp_res "$tag-L3 then Açık Ofis rollback: schema == original (v5)" "$OUT/$tag.l.schema.before" "$OUT/$tag.l.schema.after"
  "$PGBIN/dropdb" -h "$SOCK" -p "$PORT" -U postgres --if-exists --force "${db}_rt"
}
shared_ao_only

# ============================================================== (u) unified runbook order on the shared DB (docs/v2.2-runbook.md)
OPS="$ROOT/ops"
unified() {
  local tag=u db=v22_unified o
  echo "== (u) runbook order: preflight -> Kodhane -> Açık Ofis -> verify -> Açık Ofis again -> rollback Açık Ofis -> rollback Kodhane (db $db)"
  fresh_db "${db}_ao" $A_BASE
  set +e; o=$(psql_ -d "${db}_ao" -f "$OPS/v2_2_preflight.sql" 2>&1); local rc=$?; set -e
  [[ $rc != 0 && "$o" == *"WRONG TARGET"* ]] && res "$tag-P0 preflight refuses a DB without the Kodhane tables (exit $rc)" true || res "$tag-P0 preflight wrong target" false "$rc $o"
  "$PGBIN/dropdb" -h "$SOCK" -p "$PORT" -U postgres --if-exists --force "${db}_ao"
  fresh_db "$db" $S_BASE
  # two extra Kodhane players for the leaderboard diff: stage not believable for the score (5 at 2000) and no stage at all
  psql_ -d "$db" >/dev/null <<'SQL'
insert into public.kodhane_profiles (user_id, nickname) values ('33333333-3333-4333-8333-333333333333', 'Oyuncu Üç'), ('44444444-4444-4444-8444-444444444444', 'Oyuncu Dört');
insert into public.kodhane_saves (user_id, data, save_version) values
  ('33333333-3333-4333-8333-333333333333', jsonb_build_object('version', 4, 'startedAt', t.ms('20 hours'), 'lastSaved', t.ms('1 minute'), 'money', 100, 'totalEarned', 2000, 'stage', 5), 4),
  ('44444444-4444-4444-8444-444444444444', jsonb_build_object('version', 4, 'startedAt', t.ms('20 hours'), 'lastSaved', t.ms('1 minute'), 'money', 100, 'totalEarned', 40000), 4);
SQL
  psql_ -d "$db" -f "$OPS/v2_2_preflight.sql" > "$OUT/$tag.fp.before" 2> "$OUT/$tag.preflight.err"; rc=$?
  [[ $rc == 0 && $(grep -c "|" "$OUT/$tag.fp.before") == 3 ]] && grep -q "target ok" "$OUT/$tag.preflight.err" && grep -q "kodhane not applied" "$OUT/$tag.preflight.err" && grep -q "acik_ofis not applied" "$OUT/$tag.preflight.err" && grep -q "kodhane_leaderboard v5" "$OUT/$tag.preflight.err" \
    && res "$tag-P1 preflight: target ok, v2.2 not applied, leaderboard v5; fingerprint = 3 lines" true "$(tr '\n' ' ' < "$OUT/$tag.fp.before")" || res "$tag-P1 preflight" false "rc=$rc err=$(cat "$OUT/$tag.preflight.err") fp=$(cat "$OUT/$tag.fp.before")"
  psql_ -d "$db" -f "$OPS/v2_2_leaderboard_snapshot.sql" > "$OUT/$tag.lb.before"
  psql_ -d "$db" -Atc "select pg_get_functiondef('public.kodhane_leaderboard(integer,text)'::regprocedure)" > "$OUT/$tag.lbdef.before"
  dump_schema "$db" > "$OUT/$tag.schema.before"; dump_data "$db" > "$OUT/$tag.data.before"
  # (b) backup commands of the runbook (custom format, relevant tables incl. schema)
  "$PGBIN/pg_dump" -h "$SOCK" -p "$PORT" -U postgres -Fc -t public.kodhane_saves -t public.acik_ofis_saves -t public.kodhane_profiles -f "$OUT/$tag.tables.dump" "$db" \
    && [[ $("$PGBIN/pg_restore" -l "$OUT/$tag.tables.dump" | grep -c "TABLE DATA public") == 3 ]] && res "$tag-B1 runbook pg_dump -Fc of the 3 player tables restorable (pg_restore -l: 3 TABLE DATA)" true || res "$tag-B1 backup" false
  # (d) apply: Kodhane first, then Açık Ofis
  o=$(psql_ -d "$db" -1 -f "$MIG_K" 2>&1); ! grep -q ERROR <<<"$o" && res "$tag-M1 Kodhane migration (psql -1 -v ON_ERROR_STOP=1)" true || res "$tag-M1 Kodhane" false "$o"
  o=$(psql_ -d "$db" -1 -f "$MIG_A" 2>&1); ! grep -q ERROR <<<"$o" && grep -q "no shim needed" <<<"$o" && ! grep -q "shim installed" <<<"$o" \
    && res "$tag-M2 Açık Ofis migration after Kodhane: 'no shim needed', v6 not replaced" true || res "$tag-M2 Açık Ofis" false "$o"
  dump_schema "$db" > "$OUT/$tag.schema.applied"
  # (e) verify
  o=$(psql_ -d "$db" -f "$OPS/v2_2_verify.sql" 2>&1); rc=$?
  [[ $rc == 0 && "$o" == *"VERIFY OK: 18/18"* ]] && res "$tag-V1 v2_2_verify.sql: VERIFY OK 18/18" true || res "$tag-V1 verify" false "$o"
  echo "$o" > "$OUT/$tag.verify.out"
  psql_ -d "$db" -f "$OPS/v2_2_fingerprint.sql" > "$OUT/$tag.fp.applied"
  cmp_res "$tag-V2 fingerprint (rows + md5 of data/user_id/updated_at/save_version, nicknames) identical after both migrations" "$OUT/$tag.fp.before" "$OUT/$tag.fp.applied"
  psql_ -d "$db" -f "$OPS/v2_2_leaderboard_snapshot.sql" > "$OUT/$tag.lb.applied"
  local lbd; lbd=$(diff <(cut -d'|' -f1-4,6 "$OUT/$tag.lb.before") <(cut -d'|' -f1-4,6 "$OUT/$tag.lb.applied") | wc -l)
  local stg; stg=$(diff "$OUT/$tag.lb.before" "$OUT/$tag.lb.applied" | grep -c '^>' || true)
  local inf; inf=$(grep '^16|' "$OUT/$tag.verify.out" | awk -F'|' '{print $4}'); inf=${inf:-0}
  [[ $lbd == 0 && "$stg" == "$inf" && "$stg" == 2 && -z "$(diff "$OUT/$tag.lb.before" "$OUT/$tag.lb.applied" | grep '^>' | grep -v '^> kodhane|')" ]] \
    && res "$tag-V3 leaderboard before/after: game, rank, nickname, score, status identical; only $stg Kodhane stage value(s) differ (= verify info 16: $inf)" true "$(diff "$OUT/$tag.lb.before" "$OUT/$tag.lb.applied" | tr '\n' ' ')" \
    || res "$tag-V3 leaderboard diff" false "$(diff "$OUT/$tag.lb.before" "$OUT/$tag.lb.applied" | tr '\n' ' ')"
  # Açık Ofis file once more (and twice): v6 kept, schema unchanged, verify still ok
  mig "$db" "$MIG_A"; mig "$db" "$MIG_A"; dump_schema "$db" > "$OUT/$tag.schema.applied2"
  cmp_res "$tag-M3 Açık Ofis file run twice more: schema identical (kodhane_leaderboard still v6)" "$OUT/$tag.schema.applied" "$OUT/$tag.schema.applied2"
  o=$(psql_ -d "$db" -f "$OPS/v2_2_verify.sql" 2>&1); [[ "$o" == *"VERIFY OK: 18/18"* ]] && res "$tag-M4 verify after the re-runs: OK (check 11: v6, not the shim)" true || res "$tag-M4 verify re-run" false "$o"
  # (g) rollback in reverse order, with the guard flags of the runbook
  rollback "$db" "$RB_A" "v22.acik_ofis_allow_backup_loss"
  [[ "$(psql_ -d "$db" -Atc "select obj_description('public.kodhane_leaderboard(integer,text)'::regprocedure, 'pg_proc') like '%v6 (Kodhane v2.2 migration 20260928160000)%'")" == t ]] \
    && res "$tag-R1 after the Açık Ofis rollback kodhane_leaderboard is still v6 (Kodhane still applied)" true || res "$tag-R1" false
  rollback "$db" "$RB_K" "v22.kodhane_allow_backup_loss"
  psql_ -d "$db" -Atc "select pg_get_functiondef('public.kodhane_leaderboard(integer,text)'::regprocedure)" > "$OUT/$tag.lbdef.after"
  cmp_res "$tag-R2 after both rollbacks kodhane_leaderboard = the exact pre-v2.2 definition (v5)" "$OUT/$tag.lbdef.before" "$OUT/$tag.lbdef.after"
  psql_ -d "$db" -f "$OPS/v2_2_fingerprint.sql" > "$OUT/$tag.fp.after"
  cmp_res "$tag-R3 fingerprint after the rollbacks identical to before" "$OUT/$tag.fp.before" "$OUT/$tag.fp.after"
  dump_schema "$db" > "$OUT/$tag.schema.after"; dump_data "$db" > "$OUT/$tag.data.after"
  cmp_res "$tag-R4 pg_dump schema (public + auth) identical to before" "$OUT/$tag.schema.before" "$OUT/$tag.schema.after"
  cmp_res "$tag-R5 pg_dump data (public + auth) identical to before" "$OUT/$tag.data.before" "$OUT/$tag.data.after"
  psql_ -d "$db" -f "$OPS/v2_2_leaderboard_snapshot.sql" > "$OUT/$tag.lb.after"
  cmp_res "$tag-R6 leaderboard output identical to before" "$OUT/$tag.lb.before" "$OUT/$tag.lb.after"
  # hardening: even with an edited comment, the Açık Ofis file recognises v6 by its body and does not replace it
  mig "$db" "$MIG_K"; psql_ -d "$db" -c "comment on function public.kodhane_leaderboard(int, text) is 'edited by hand'" >/dev/null
  o=$(psql_ -d "$db" -f "$MIG_A" 2>&1)
  [[ "$o" == *"no shim needed"* && "$(psql_ -d "$db" -Atc "select pg_get_functiondef('public.kodhane_leaderboard(integer,text)'::regprocedure) like '%s.data, s.best_score, s.best_stage%'")" == t ]] \
    && res "$tag-H1 Kodhane v6 with an edited comment: Açık Ofis file still leaves v6 alone (body check)" true || res "$tag-H1 shim guard" false "$o"
  "$PGBIN/dropdb" -h "$SOCK" -p "$PORT" -U postgres --if-exists --force "$db"
}
unified

# ============================================================== fresh Kodhane install from the kodhane-cloud files (v6)
if [[ -f "$KC/schema.sql" && -f "$KC/leaderboard.sql" ]]; then
  echo "== fresh install: kodhane-cloud schema.sql + leaderboard.sql (v6), then the Kodhane migration"
  "$PGBIN/dropdb" -h "$SOCK" -p "$PORT" -U postgres --if-exists --force v22_fresh; "$PGBIN/createdb" -h "$SOCK" -p "$PORT" -U postgres v22_fresh
  psql_ -d v22_fresh -f "$FIX/stub_supabase.sql"
  for f in schema.sql leaderboard.sql; do psql_ -d v22_fresh -f "$KC/$f" >/dev/null 2>&1 || echo "  $f failed"; done
  pre=$(psql_ -d v22_fresh -Atc "select count(*) from pg_proc where proname in ('kodhane_leaderboard', 'acik_ofis_score_plausible')")
  mig v22_fresh "$MIG_K"
  out=$(psql_ -d v22_fresh -Atc "select count(*) from public.kodhane_leaderboard(50, 'kodhane')" 2>&1 || true)
  [[ "$pre" == 0 && "$out" == 0 ]] && res "F1 fresh Kodhane DB: leaderboard.sql v6 creates no RPC (and no Açık Ofis function); the Kodhane migration does" true \
    || res "F1 fresh install" false "pre=$pre out=$out"
  "$PGBIN/dropdb" -h "$SOCK" -p "$PORT" -U postgres --if-exists --force v22_fresh
fi

echo "== summary"
awk -F'\t' '{split($1,a,"|"); m=(index($1,"|")?a[1]:"runner"); n[m]++; if($2=="true"||$2=="t") p[m]++; else f[m]++} END {for (k in n) printf "  %-8s %d/%d\n", k, p[k], n[k]}' "$RES" | sort
TOTAL=$(wc -l < "$RES"); PASSED=$(awk -F'\t' '$2=="true"||$2=="t"' "$RES" | wc -l)
echo "$PASSED passed, $((TOTAL - PASSED)) failed, $TOTAL total   (details: $RES)"
[[ "$PASSED" == "$TOTAL" ]] || { awk -F'\t' '!($2=="true"||$2=="t")' "$RES"; exit 1; }
