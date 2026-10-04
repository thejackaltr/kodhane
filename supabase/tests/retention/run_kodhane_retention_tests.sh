#!/usr/bin/env bash
# Kodhane retention (todo 26) tests: auth.audit_log_entries 12 months (migration 20261001210000), save backups 30 days
# (existing v2.2 kodhane_cleanup_save_backups() / acik_ofis_cleanup_save_backups()), the daily job and its Dokploy wrapper.
# LOCAL THROWAWAY DATABASES ONLY, in the local docker container $KR_CT (supabase/postgres image) whose database $KR_BASE
# holds the live schema (no data). Never point this at the live DB: it drops/creates databases and deletes rows.
#   KR_CT=<container> bash supabase/tests/retention/run_kodhane_retention_tests.sh 2>&1 | tee /tmp/kd-ret-test.log
# Groups: M migration, P privileges, A audit retention, B backup retention, S local job script, Q role postgres,
# D / J Dokploy compose task command, run exactly as Dokploy does (docker exec <c> sh -c '<command>'), R rollback.
# J temporarily replaces the container's own postgres database with the live schema and restores it at the end.
# Progress log (kazanc gunlugu, migration 20261003020000, 365 days): LAST step of the local job (skipped without the migration)
# and of the second Dokploy command file (..._with_progress_log.txt, used once the migration is live): M4, S1-S2, S7-S8b,
# D0-D0e, JS1-JS2 (first command alone, without / with the progress log), J1-J6, J8-J9 (second command).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CT="${KR_CT:-kdret-db136}"; BASE="${KR_BASE:-v44_base}"; OUT="${KR_OUT:-/tmp/kd-ret-test}"; mkdir -p "$OUT"; chmod 700 "$OUT"
MIG="$ROOT/migrations/20261001210000_v4_4_kodhane_audit_log_retention.sql"
RB="$ROOT/rollback/20261001210000_v4_4_kodhane_audit_log_retention.rollback.sql"
MIGL="$ROOT/migrations/20261003020000_v4_4_kodhane_progress_log.sql"; RBL="$ROOT/rollback/20261003020000_v4_4_kodhane_progress_log.rollback.sql"
JOB="$ROOT/ops/kodhane_retention_daily.sh"; CMDF="$ROOT/ops/kodhane_retention_dokploy_command.txt"; CMDLF="$ROOT/ops/kodhane_retention_dokploy_command_with_progress_log.txt"; RUNBOOK="$ROOT/../docs/kodhane-retention-runbook.md"
FN='public.kodhane_cleanup_audit_log(integer)'; CALL='public.kodhane_cleanup_audit_log(10)'; ACL='{postgres=X/postgres,service_role=X/postgres}'
U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
PA() { P -At -F '|' "$@"; }
PE() { docker exec -i -e PGOPTIONS='-c kodhane.progress_log_allow_loss=on' "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
migl() { P -d "$1" -f - < "$MIGL" > "$OUT/$2" 2>&1; }
rbl() { PE -d "$1" -f - < "$RBL" > "$OUT/$2" 2>&1; }
# progress log row: add_pl <db> <n> <age sql> <tag>  (tag kept in client_version; user U1 must exist)
add_pl() { PA -d "$1" -c "insert into public.kodhane_progress_log (user_id, client_version, event, field, old_value, new_value, actor_role, created_at)
  select '$U1', '$4', 'yatirim_turu', 'shares', g, g + 1, 'kr-test', now() - ($3) from generate_series(1, $2) g" >/dev/null; }
pl_n() { PA -d "$1" -c "select count(*) from public.kodhane_progress_log where client_version = '$2'"; }
FAILS=0; PASSN=0
pass() { echo "PASS $*"; PASSN=$((PASSN+1)); }
fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
check() { local name=$1 got=$2 want=$3; if [[ "$got" == "$want" ]]; then pass "$name  -- $got"; else fail "$name: got '$got', want '$want'"; fi; }
fresh() { P -d postgres -c "drop database if exists $1" -c "create database $1 template $BASE" >/dev/null 2>&1; }
dump() { docker exec "$CT" pg_dump -U supabase_admin --schema-only -n public -n auth "$1" | grep -v '^\\\(un\)\?restrict '; }
mig() { P -d "$1" -f - < "$MIG" > "$OUT/$2" 2>&1; }
fn_state() { PA -d "$1" -c "select coalesce((select pg_get_userbyid(p.proowner) || '|' || p.prosecdef || '|' || array_to_string(p.proconfig, ',') || '|' || p.proacl::text
                                              from pg_proc p where p.oid = to_regprocedure('$FN')), 'absent')"; }
audit_n() { PA -d "$1" -c "select count(*) from auth.audit_log_entries"; }
# audit row: add_audit <db> <n> <age sql, e.g. "interval '12 months' + interval '1 day'" or null> <tag>
add_audit() { local ts="now() - ($3)"; [[ $3 == null ]] && ts="null::timestamptz"
  PA -d "$1" -c "insert into auth.audit_log_entries (instance_id, id, payload, created_at)
  select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), json_build_object('action', 'kr-test', 'tag', '$4', 'i', g),
         $ts from generate_series(1, $2) g" >/dev/null; }
# pg_dump without the blocks whose '-- Name:' header matches $2 (drops one object's definition / ACL / comment)
dump_minus() { python3 -c '
import re, sys
txt = open(sys.argv[1]).read(); rx = re.compile(sys.argv[2])
parts = re.split(r"(?m)^(?=--\n-- Name: )", txt)
sys.stdout.write("".join(b for b in parts if not rx.search(b.split("\n")[1] if b.startswith("--\n-- Name: ") else "")))
' "$1" "$2"; }
tag_n() { PA -d "$1" -c "select count(*) from auth.audit_log_entries where payload ->> 'tag' = '$2'"; }

echo "== container $CT: $(docker inspect -f '{{.Config.Image}} {{.Image}}' "$CT" | cut -c1-80)"

# ------------------------------------------------------------------ M: migration
fresh kr_main; dump kr_main > "$OUT/dump_before.sql"
fresh kr_noperm
P -d kr_noperm -c "revoke delete on auth.audit_log_entries from postgres" >/dev/null
r=$(PA -d kr_noperm -c "select has_table_privilege('postgres', 'auth.audit_log_entries', 'DELETE')")
if [[ $r == f ]] && ! mig kr_noperm m0.log && grep -q 'role postgres cannot DELETE auth.audit_log_entries' "$OUT/m0.log" \
   && [[ $(fn_state kr_noperm) == absent ]]; then
  pass "M0 postgres without DELETE on auth.audit_log_entries -> migration stops with an error, function not created  -- $(grep -m1 -oE 'ERROR: .*' "$OUT/m0.log" | cut -c1-130)"
else fail "M0 has_table_privilege=$r, $(grep -m1 -oE 'ERROR: .*' "$OUT/m0.log"), fn $(fn_state kr_noperm)"; fi
P -d kr_noperm -c "grant delete on auth.audit_log_entries to postgres" >/dev/null
fresh kr_wrong; P -d kr_wrong -c "alter table public.kodhane_saves rename to kodhane_saves_x" >/dev/null
if ! mig kr_wrong m0b.log && grep -q 'wrong target' "$OUT/m0b.log" && [[ $(fn_state kr_wrong) == absent ]]; then pass "M0b wrong target (no public.kodhane_saves) -> error, nothing created"
else fail "M0b $(grep -m1 -oE 'ERROR: .*' "$OUT/m0b.log")"; fi
if mig kr_main m1.log; then check "M1 migration applies: owner | security definer | search_path | ACL (postgres + service_role only)" "$(fn_state kr_main)" "postgres|true|search_path=\"\"|$ACL"
else fail "M1 migration failed: $(grep -m1 -oE 'ERROR: .*' "$OUT/m1.log")"; fi
d1=$(PA -d kr_main -c "select md5(pg_get_functiondef(to_regprocedure('$FN')))")
if mig kr_main m2.log; then check "M2 second run (idempotent): same definition and ACL" "$(fn_state kr_main)|$(PA -d kr_main -c "select md5(pg_get_functiondef(to_regprocedure('$FN')))")" "postgres|true|search_path=\"\"|$ACL|$d1"
else fail "M2 second run failed"; fi
dump kr_main > "$OUT/dump_after.sql"
r=$(dump_minus "$OUT/dump_after.sql" 'kodhane_cleanup_audit_log\(' | diff "$OUT/dump_before.sql" - | grep -cE '^[<>]')
check "M3 the migration adds only kodhane_cleanup_audit_log (public + auth schema diff without its blocks)" "$r" 0
check "M3b function, ACL and comment blocks present (3)" "$(grep -c '^-- Name: .*kodhane_cleanup_audit_log(' "$OUT/dump_after.sql")" 3
if migl kr_main m4.log && [[ $(PA -d kr_main -c "select to_regprocedure('public.kodhane_cleanup_progress_log(integer,integer)') is not null") == t ]]; then
  pass "M4 progress log migration (20261003020000) applied on top, for the S / J steps"
else fail "M4 $(grep -m1 -oE 'ERROR: .*' "$OUT/m4.log")"; fi

# ------------------------------------------------------------------ P: privileges
for role in anon authenticated; do
  if PA -d kr_main -c "set role $role" -c "select $CALL" 2>"$OUT/p_$role.log" >/dev/null; then fail "P-$role $role could call the audit cleanup"
  elif grep -q 'permission denied for function kodhane_cleanup_audit_log' "$OUT/p_$role.log"; then pass "P-$role $role cannot EXECUTE kodhane_cleanup_audit_log (42501)"
  else fail "P-$role wrong error: $(cat "$OUT/p_$role.log")"; fi
  for f in kodhane_cleanup_save_backups acik_ofis_cleanup_save_backups; do
    if PA -d kr_main -c "set role $role" -c "select public.$f()" 2>"$OUT/p_${role}_$f.log" >/dev/null; then fail "P-$role-$f callable"
    elif grep -q "permission denied for function $f" "$OUT/p_${role}_$f.log"; then pass "P-$role-$f $role cannot EXECUTE $f() (42501)"
    else fail "P-$role-$f wrong error: $(cat "$OUT/p_${role}_$f.log")"; fi
  done
done
check "P-public no PUBLIC EXECUTE and exactly postgres + service_role on the three cleanup functions" \
  "$(PA -d kr_main -c "select string_agg(p.proname || '=' || p.proacl::text, ' ' order by p.proname) from pg_proc p
     where p.oid in (to_regprocedure('$FN'), 'public.kodhane_cleanup_save_backups()'::regprocedure, 'public.acik_ofis_cleanup_save_backups()'::regprocedure)")" \
  "acik_ofis_cleanup_save_backups=$ACL kodhane_cleanup_audit_log=$ACL kodhane_cleanup_save_backups=$ACL"
add_audit kr_main 3 "interval '13 months'" p_sr
check "P-service_role service_role can EXECUTE (security definer deletes in auth) and gets the count" "$(PA -d kr_main -c "set role service_role" -c "select $CALL" -c "select public.kodhane_cleanup_save_backups()" -c "select public.acik_ofis_cleanup_save_backups()" | tr '\n' ' ')" "3 0 0 "
check "P-postgres postgres (owner) can EXECUTE" "$(PA -d kr_main -c "set role postgres" -c "select public.kodhane_cleanup_audit_log(10)")" 0

# ------------------------------------------------------------------ A: audit retention, 12 months
add_audit kr_main 3 "interval '12 months' + interval '1 day'" old       # 12 months + 1 day old -> deleted
add_audit kr_main 2 "interval '12 months' - interval '1 day'" young     # 1 day short of 12 months -> kept
add_audit kr_main 1 "null" nullts                                        # created_at null -> kept
add_audit kr_main 2 "interval '1 hour'" recent
before=$(audit_n kr_main)
r=$(PA -d kr_main -c "select public.kodhane_cleanup_audit_log(1000)")
check "A1 12 months + 1 day deleted, 12 months - 1 day kept: returned count" "$r" 3
check "A2 rows left per tag (old / young / null created_at / recent)" "$(tag_n kr_main old)/$(tag_n kr_main young)/$(tag_n kr_main nullts)/$(tag_n kr_main recent)" "0/2/1/2"
check "A3 returned count = rows actually deleted" "$((before - $(audit_n kr_main)))" "$r"
check "A4 nothing older than 12 months: a second call returns 0" "$(PA -d kr_main -c "select public.kodhane_cleanup_audit_log(1000)")" 0
add_audit kr_main 25 "interval '400 days'" batch
r=""; for k in 1 2 3 4; do r="$r$(PA -d kr_main -c "select public.kodhane_cleanup_audit_log(10)") "; done
check "A5 batch limit: 25 old rows with batch 10 -> 10, 10, 5, 0" "$r" "10 10 5 0 "
add_audit kr_main 2 "interval '500 days'" oldest; add_audit kr_main 2 "interval '450 days'" older
check "A6 oldest rows first: batch 2 takes the 500-day rows, then the 450-day rows" "$(PA -d kr_main -c "select public.kodhane_cleanup_audit_log(2)")/$(tag_n kr_main oldest)/$(tag_n kr_main older)" "2/0/2"
P -d kr_main -c "select public.kodhane_cleanup_audit_log(2)" >/dev/null
add_audit kr_main 4 "interval '13 months'" bad; n0=$(audit_n kr_main)
for b in 0 -1 null 50001; do
  if PA -d kr_main -c "select public.kodhane_cleanup_audit_log($b)" 2>"$OUT/a7_$b.log" >/dev/null; then fail "A7 batch $b accepted"
  elif grep -q 'p_batch_size must be between 1 and 50000' "$OUT/a7_$b.log" && [[ $(audit_n kr_main) == "$n0" ]]; then pass "A7 batch $b refused (22023), nothing deleted"
  else fail "A7 batch $b: $(cat "$OUT/a7_$b.log"), rows $(audit_n kr_main) / $n0"; fi
done
check "A8 batch 50000 (the maximum) accepted" "$(PA -d kr_main -c "select public.kodhane_cleanup_audit_log(50000)")" 4
add_audit kr_main 3 "interval '13 months'" dflt
check "A9 default batch (no argument) works" "$(PA -d kr_main -c "select public.kodhane_cleanup_audit_log()")" 3
add_audit kr_main 2 "interval '13 months'" tx
r=$(PA -d kr_main -c "begin" -c "select public.kodhane_cleanup_audit_log(10)" -c "rollback")
check "A10 a rolled back call: returns 2 inside the transaction, deletes nothing" "$r|$(tag_n kr_main tx)" "2|2"
P -d kr_main -c "select public.kodhane_cleanup_audit_log(10)" >/dev/null

# ------------------------------------------------------------------ B: save backups, 30 days (existing functions)
P -d kr_main -c "insert into auth.users (id) values ('$U1'), ('$U2')" >/dev/null
add_bk() {   # add_bk <db> <table> <user> <reason> <age sql> <tag>
  PA -d "$1" -c "insert into public.$2 (user_id, revision, payload, reason, created_at) values ('$3', 1, jsonb_build_object('tag', '$6'), '$4', now() - ($5))" >/dev/null; }
bk_tags() { PA -d "$1" -c "select coalesce(string_agg(payload ->> 'tag', ',' order by payload ->> 'tag'), '') from public.$2"; }
for t in kodhane_save_backups acik_ofis_save_backups; do
  add_bk kr_main $t $U1 reset  "interval '31 days'" reset31
  add_bk kr_main $t $U1 delete "interval '31 days'" delete31
  add_bk kr_main $t $U2 manual "interval '29 days'" manual29
  add_bk kr_main $t $U2 delete "interval '29 days'" delete29
  add_bk kr_main $t $U2 restore "interval '1 hour'" restore0
done
check "B0 retention setting is 30 days in both games" "$(PA -d kr_main -c "select public.kodhane_save_backup_retention() || '/' || public.acik_ofis_save_backup_retention()")" "30 days/30 days"
check "B1 kodhane_cleanup_save_backups(): 30 days + 1 day deleted (delete copy included), returned count" "$(PA -d kr_main -c "select public.kodhane_cleanup_save_backups()")" 2
check "B2 Kodhane backups left (29 days kept, delete copy included)" "$(bk_tags kr_main kodhane_save_backups)" "delete29,manual29,restore0"
check "B3 acik_ofis backups untouched by the Kodhane cleanup" "$(bk_tags kr_main acik_ofis_save_backups)" "delete29,delete31,manual29,reset31,restore0"
check "B4 acik_ofis_cleanup_save_backups(): returned count" "$(PA -d kr_main -c "select public.acik_ofis_cleanup_save_backups()")" 2
check "B5 Açık Ofis backups left" "$(bk_tags kr_main acik_ofis_save_backups)" "delete29,manual29,restore0"
check "B6 second run deletes nothing" "$(PA -d kr_main -c "select public.kodhane_cleanup_save_backups() || '/' || public.acik_ofis_cleanup_save_backups()")" "0/0"

# ------------------------------------------------------------------ S: local job script (test tool; Dokploy uses the one-line command, see D / J)
if grep -nE 'PGPASSWORD=[^"]|POSTGRES_PASSWORD=|^[[:space:]]*set -[a-z]*x|eyJ' "$JOB" "$CMDF" >/dev/null; then fail "S0b secret-like literal or set -x in the job files"; else pass "S0b no credential, no set -x in the local job script and the Dokploy command"; fi
job() { docker exec -i "$@" "$CT" sh -s < "$JOB"; }
add_audit kr_main 10 "interval '13 months'" s1; add_audit kr_main 1 "interval '11 months'" s1keep
for t in kodhane_save_backups acik_ofis_save_backups; do add_bk kr_main $t $U1 delete "interval '40 days'" s1; done
add_pl kr_main 10 "interval '366 days'" s1; add_pl kr_main 1 "interval '364 days'" s1keep
o=$(job -e KD_DB=kr_main -e KD_AUDIT_BATCH=4 2>&1); rc=$?
check "S1 daily job: both backup tables + audit in batches, then progress log (365 days) in batches, exit 0" "$rc|$(sed -E 's/^[0-9TZ:-]+ //' <<<"$o" | tr '\n' '#')" \
  "0|kodhane retention OK: kodhane_save_backups 1, acik_ofis_save_backups 1, audit_log_entries 10 (3 batch(es) of <= 4); audit rows older than 12 months left 0#kodhane retention progress log OK: kodhane_progress_log 10 (3 batch(es) of <= 4); rows older than 365 days left 0#kodhane retention deletion log skipped: migration 20261003040000 not applied in database kr_main#kodhane retention loss reports skipped: migration 20261003060000 not applied in database kr_main#"
check "S1b kept: the 11-month audit row and the 364-day progress log row" "$(tag_n kr_main s1keep)/$(pl_n kr_main s1keep)/$(pl_n kr_main s1)" 1/1/0
o=$(job -e KD_DB=kr_main 2>&1); rc=$?
check "S2 second run: nothing to delete" "$rc|$(sed -E 's/^[0-9TZ:-]+ //' <<<"$o" | tr '\n' '#')" \
  "0|kodhane retention OK: kodhane_save_backups 0, acik_ofis_save_backups 0, audit_log_entries 0 (1 batch(es) of <= 5000); audit rows older than 12 months left 0#kodhane retention progress log OK: kodhane_progress_log 0 (1 batch(es) of <= 5000); rows older than 365 days left 0#kodhane retention deletion log skipped: migration 20261003040000 not applied in database kr_main#kodhane retention loss reports skipped: migration 20261003060000 not applied in database kr_main#"
add_audit kr_main 10 "interval '13 months'" s3
o=$(job -e KD_DB=kr_main -e KD_AUDIT_BATCH=4 -e KD_AUDIT_MAX_BATCHES=2 2>&1); rc=$?
if [[ $rc == 0 && "$o" == *"audit_log_entries 8 (2 batch(es) of <= 4); audit rows older than 12 months left 2"* && "$o" == *"batch cap reached"* ]]; then pass "S3 batch cap: 8 of 10 deleted, 2 left for the next run, exit 0"
else fail "S3 rc $rc: $o"; fi
P -d kr_main -c "select public.kodhane_cleanup_audit_log(10)" >/dev/null
o=$(job -e KD_DB=postgres 2>&1); rc=$?
if [[ $rc == 3 && "$o" == *"wrong target or migration missing in database postgres"* ]]; then pass "S4 wrong database -> exit 3, nothing run"; else fail "S4 rc $rc: $o"; fi
add_audit kr_noperm 2 "interval '13 months'" s5
o=$(job -e KD_DB=kr_noperm 2>&1); rc=$?
if [[ $rc == 3 && $(tag_n kr_noperm s5) == 2 ]]; then pass "S5 migration not applied -> exit 3, nothing deleted"; else fail "S5 rc $rc: $o"; fi
for b in abc 0 50001; do
  o=$(job -e KD_DB=kr_main -e KD_AUDIT_BATCH=$b 2>&1); rc=$?
  [[ $rc == 2 ]] && pass "S6 KD_AUDIT_BATCH=$b -> exit 2" || fail "S6 KD_AUDIT_BATCH=$b rc $rc: $o"
done
P -d kr_main -c "alter table public.acik_ofis_save_backups rename to acik_ofis_save_backups_kr" >/dev/null
add_audit kr_main 2 "interval '13 months'" s7; add_pl kr_main 2 "interval '400 days'" s7
o=$(job -e KD_DB=kr_main 2>&1); rc=$?
if [[ $rc != 0 && "$o" != *"retention OK"* && "$o" == *'relation "public.acik_ofis_save_backups" does not exist'* && $(tag_n kr_main s7) == 2 && $(pl_n kr_main s7) == 2 ]]; then
  pass "S7 a failing step (Açık Ofis cleanup, table renamed) stops the job: exit $rc, no OK line, the audit and progress log steps did not run"
else fail "S7 rc $rc, s7 rows $(tag_n kr_main s7) / $(pl_n kr_main s7): $o"; fi
P -d kr_main -c "alter table public.acik_ofis_save_backups_kr rename to acik_ofis_save_backups" >/dev/null
check "S7b table name restored" "$(PA -d kr_main -c "select to_regclass('public.acik_ofis_save_backups') is not null")" t
# S8: progress log migration missing (rolled back) -> steps 1-3 done, the last step is skipped (retention installed first)
rbl kr_main s8rb.log; add_audit kr_main 3 "interval '13 months'" s8
for t in kodhane_save_backups acik_ofis_save_backups; do add_bk kr_main $t $U1 delete "interval '40 days'" s8; done
o=$(job -e KD_DB=kr_main 2>&1); rc=$?
s8bk=$(PA -d kr_main -c "select (select count(*) from public.kodhane_save_backups where payload ->> 'tag' = 's8') + (select count(*) from public.acik_ofis_save_backups where payload ->> 'tag' = 's8')")
if [[ $rc == 0 && "$o" == *"kodhane retention OK: kodhane_save_backups 1, acik_ofis_save_backups 1, audit_log_entries 5 "* \
      && "$o" == *"kodhane retention progress log skipped: migration 20261003020000 not applied in database kr_main"* && "$o" != *ERROR* \
      && $(tag_n kr_main s8) == 0 && $s8bk == 0 ]]; then
  pass "S8 progress log migration missing: backups + audit deleted (s8 rows 0), progress log step skipped, exit 0"
else fail "S8 rc $rc, audit s8 $(tag_n kr_main s8), backups s8 $s8bk: $o"; fi
migl kr_main s8m.log; add_pl kr_main 2 "interval '366 days'" s8b
o=$(job -e KD_DB=kr_main 2>&1); rc=$?
if [[ $rc == 0 && "$o" == *"kodhane retention progress log OK: kodhane_progress_log 2 (1 batch(es) of <= 5000); rows older than 365 days left 0"* ]]; then
  pass "S8b migration re-applied: the job succeeds again and deletes the 366-day progress log rows"
else fail "S8b rc $rc: $o"; fi
# ------------------------------------------------------------------ Q: role postgres (not supabase_admin) calls and deletes
PG() { docker exec -i "$CT" psql -U postgres -X -q -v ON_ERROR_STOP=1 -At -F '|' "$@"; }
P -d kr_main -c "select public.kodhane_cleanup_audit_log(1000)" >/dev/null   # leftovers of S7
check "Q0 connected as role postgres (session_user postgres, not a superuser)" "$(PG -d kr_main -c "select current_user || '|' || session_user || '|' || (select rolsuper from pg_roles where rolname = current_user)")" "postgres|postgres|false"
add_audit kr_main 3 "interval '13 months'" q; add_audit kr_main 1 "interval '11 months'" qkeep
for t in kodhane_save_backups acik_ofis_save_backups; do add_bk kr_main $t $U2 delete "interval '35 days'" q; add_bk kr_main $t $U2 reset "interval '31 days'" q; add_bk kr_main $t $U2 manual "interval '2 days'" qkeep; done
check "Q1 postgres calls the three functions: kodhane backups / acik_ofis backups / audit counts" "$(PG -d kr_main -c "select public.kodhane_cleanup_save_backups()" -c "select public.acik_ofis_cleanup_save_backups()" -c "select public.kodhane_cleanup_audit_log(10)" | tr '\n' ' ')" "2 2 3 "
bk_tag_n() { PA -d "$1" -c "select count(*) from public.$2 where payload ->> 'tag' = '$3'"; }
check "Q2 the rows are really gone, the young ones stay (audit / kodhane / ao: old | kept)" \
  "$(tag_n kr_main q)/$(bk_tag_n kr_main kodhane_save_backups q)/$(bk_tag_n kr_main acik_ofis_save_backups q)|$(tag_n kr_main qkeep)/$(bk_tag_n kr_main kodhane_save_backups qkeep)/$(bk_tag_n kr_main acik_ofis_save_backups qkeep)" "0/0/0|1/1/1"

# ------------------------------------------------------------------ D: Dokploy compose task (one-line command, db service)
CMD=$(cat "$CMDF"); CMDL=$(cat "$CMDLF")
check "D0 both command files are exactly one line" "$(wc -l < "$CMDF")/$(wc -l < "$CMDLF")" 1/1
if grep -q "['\$\`\\\\]" "$CMDF" "$CMDLF"; then fail "D0b a command contains a single quote, dollar, backtick or backslash"; else pass "D0b no single quote, dollar, backtick or backslash in either command: safe inside sh -c '...' as is"; fi
miss=""; for o in "psql -X -P pager=off -U postgres -d postgres -v ON_ERROR_STOP=1 -x " "public.kodhane_cleanup_save_backups()" "public.acik_ofis_cleanup_save_backups()" "public.kodhane_cleanup_audit_log(5000)"; do [[ "$CMD" == *"$o"* ]] || miss="$miss $o"; done
[[ "$CMD" == *progress_log* ]] && miss="$miss (mentions progress_log)"
check "D0c first command: -X -P pager=off -U postgres -d postgres -v ON_ERROR_STOP=1, three functions, no progress log" "${miss:-none missing}" "none missing"
if grep -qxF "$CMD" "$RUNBOOK" && grep -qxF "$CMDL" "$RUNBOOK"; then pass "D0d runbook contains both commands verbatim (own lines)"; else fail "D0d runbook does not contain both commands verbatim"; fi
if [[ "$CMDL" == "$CMD -c "* && "$CMDL" == *"public.kodhane_cleanup_progress_log(365, 5000)"* && "$CMDL" == *"progress_log_left_over_365d"* ]]; then
  pass "D0e second command = first command verbatim + progress log steps at the end (kodhane_cleanup_progress_log(365, 5000))"
else fail "D0e second command does not start with the first one or lacks the progress log step"; fi
check "D1 image default user (Config.User empty -> root) and the user docker exec runs as" "[$(docker inspect -f '{{.Config.User}}' "$CT")] $(docker exec "$CT" id -un)" "[] root"
check "D2 pg_hba (.136, $(PA -d postgres -c "show hba_file")): local socket rules" "$(PA -d postgres -c "select string_agg(type || ' ' || array_to_string(database, ',') || ' ' || array_to_string(user_name, ',') || ' ' || auth_method || coalesce(' ' || array_to_string(options, ','), ''), '; ' order by rule_number) from pg_hba_file_rules where type = 'local'")" "local all supabase_admin trust; local all all peer map=supabase_map"
check "D2b pg_ident supabase_map: OS user root -> db role postgres (peer, no password)" "$(PA -d postgres -c "select string_agg(sys_name || '>' || pg_username, ' ' order by sys_name) from pg_ident_file_mappings where map_name = 'supabase_map' and sys_name in ('root', 'postgres')")" "postgres>postgres root>postgres"
check "D3 as root: psql -U postgres over the local socket, no password (PGPASSWORD / PGHOST unset)" "$(docker exec "$CT" sh -c 'env -u PGPASSWORD -u PGHOST psql -X -U postgres -d postgres -Atc "select current_user || chr(32) || (inet_client_addr() is null)::text"' 2>&1)" "postgres true"
P -d template1 -c "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'postgres' and pid <> pg_backend_pid()" \
  -c "alter database postgres rename to kr_postgres_orig" -c "create database postgres template $BASE" >/dev/null
if mig postgres j0.log; then pass "J0 throwaway postgres database = live schema + audit migration, no progress log (as in production: -d postgres)"; else fail "J0 $(cat "$OUT/j0.log")"; fi
P -d postgres -c "insert into auth.users (id) values ('$U1')" >/dev/null
dok() { sh -c "docker exec $CT sh -c '${2:-$CMDL}'" > "$OUT/$1" 2>&1; echo $?; }   # exactly what Dokploy runs (default: second command)
vals() { grep -E '^[a-z_0-9]+ +\| ' "$OUT/$1" | sed -E 's/ +\| /=/' | tr '\n' ' '; }
add_audit postgres 2 "interval '13 months'" js1
rc=$(dok js1.out "$CMD")
check "JS1 retention installed alone (no progress log table / function): first command succeeds" "rc=$rc $(vals js1.out)$(grep -c ERROR "$OUT/js1.out")" \
  "rc=0 kodhane_save_backups=0 acik_ofis_save_backups=0 audit_log_entries=2 audit_batches=1 audit_left_over_12m=0 0"
if migl postgres j0l.log; then pass "J0b progress log migration applied (from here on the second command)"; else fail "J0b $(cat "$OUT/j0l.log")"; fi
add_audit postgres 12001 "interval '13 months'" j1; add_audit postgres 2 "interval '12 months' - interval '1 day'" j1keep
for t in kodhane_save_backups acik_ofis_save_backups; do add_bk postgres $t $U1 delete "interval '40 days'" j1; add_bk postgres $t $U1 reset "interval '31 days'" j1; add_bk postgres $t $U1 manual "interval '29 days'" j1keep; done
add_pl postgres 12001 "interval '366 days'" j1; add_pl postgres 2 "interval '364 days'" j1keep
rc=$(dok j1.out)
check "J1 docker exec <c> sh -c '<command>' (default user root): counts on stdout, exit code" "rc=$rc $(vals j1.out)" \
  "rc=0 kodhane_save_backups=2 acik_ofis_save_backups=2 audit_log_entries=12001 audit_batches=3 audit_left_over_12m=0 progress_log_rows=12001 progress_log_batches=3 progress_log_left_over_365d=0 "
check "J1b kept: audit 12 months - 1 day, both games' 29-day backups, progress log 364 days" "$(tag_n postgres j1keep)/$(PA -d postgres -c "select count(*) from public.kodhane_save_backups")/$(PA -d postgres -c "select count(*) from public.acik_ofis_save_backups")/$(pl_n postgres j1keep)/$(pl_n postgres j1)" "2/1/1/2/0"
rc=$(dok j2.out)
check "J2 second run: zeros, exit code" "rc=$rc $(vals j2.out)" "rc=0 kodhane_save_backups=0 acik_ofis_save_backups=0 audit_log_entries=0 audit_batches=0 audit_left_over_12m=0 progress_log_rows=0 progress_log_batches=0 progress_log_left_over_365d=0 "
add_audit postgres 100005 "interval '13 months'" j3; add_pl postgres 100005 "interval '400 days'" j3
rc=$(dok j3.out)
check "J3 upper bound 20 batches x 5000 per run (audit and progress log): 100000 deleted each, 5 left for the next night, exit code" "rc=$rc $(vals j3.out)" \
  "rc=0 kodhane_save_backups=0 acik_ofis_save_backups=0 audit_log_entries=100000 audit_batches=20 audit_left_over_12m=5 progress_log_rows=100000 progress_log_batches=20 progress_log_left_over_365d=5 "
rc=$(dok j3b.out)
check "J3b next run deletes the rest" "rc=$rc $(vals j3b.out)" "rc=0 kodhane_save_backups=0 acik_ofis_save_backups=0 audit_log_entries=5 audit_batches=1 audit_left_over_12m=0 progress_log_rows=5 progress_log_batches=1 progress_log_left_over_365d=0 "
P -d postgres -f - < "$RB" >/dev/null 2>&1; add_audit postgres 2 "interval '13 months'" j4; add_pl postgres 2 "interval '400 days'" j4
rc=$(dok j4.out)
if [[ $rc != 0 ]] && grep -q 'function public.kodhane_cleanup_audit_log(integer) does not exist' "$OUT/j4.out" && [[ $(tag_n postgres j4) == 2 && $(pl_n postgres j4) == 2 ]]; then
  pass "J4 audit function missing (rollback applied) -> exit code $rc, ERROR in the log, nothing deleted from the audit log or the progress log  -- $(grep -m1 -oE 'ERROR: .*' "$OUT/j4.out" | cut -c1-90)"
else fail "J4 rc $rc: $(cat "$OUT/j4.out")"; fi
mig postgres j4m.log
P -d postgres -c "alter table public.acik_ofis_save_backups rename to acik_ofis_save_backups_kr" >/dev/null
rc=$(dok j5.out)
if [[ $rc != 0 ]] && grep -q 'relation "public.acik_ofis_save_backups" does not exist' "$OUT/j5.out" && [[ $(tag_n postgres j4) == 2 ]] && ! grep -q audit_log_entries "$OUT/j5.out"; then
  pass "J5 first step fails (Açık Ofis table renamed) -> exit code $rc, later steps not run (audit rows still there)"
else fail "J5 rc $rc: $(cat "$OUT/j5.out")"; fi
P -d postgres -c "alter table public.acik_ofis_save_backups_kr rename to acik_ofis_save_backups" >/dev/null
rc=$(dok j6.out)
check "J6 after the fix the same command succeeds again" "rc=$rc $(vals j6.out)" "rc=0 kodhane_save_backups=0 acik_ofis_save_backups=0 audit_log_entries=2 audit_batches=1 audit_left_over_12m=0 progress_log_rows=2 progress_log_batches=1 progress_log_left_over_365d=0 "
# J8: progress log migration missing (rolled back): the first three -c steps run and commit, the last step fails
rbl postgres j8rb.log; add_audit postgres 3 "interval '13 months'" j8
for t in kodhane_save_backups acik_ofis_save_backups; do add_bk postgres $t $U1 delete "interval '40 days'" j8; done
rc=$(dok j8.out)
if [[ $rc == 1 ]] && grep -q 'function public.kodhane_cleanup_progress_log(integer, integer) does not exist' "$OUT/j8.out" \
   && [[ "$(vals j8.out)" == "kodhane_save_backups=1 acik_ofis_save_backups=1 audit_log_entries=3 audit_batches=1 audit_left_over_12m=0 " ]] \
   && [[ $(tag_n postgres j8) == 0 && $(PA -d postgres -c "select count(*) from public.kodhane_save_backups") == 1 && $(PA -d postgres -c "select count(*) from public.acik_ofis_save_backups") == 1 ]]; then
  pass "J8 progress log function missing -> exit 1 at the last step; backups and audit already deleted and committed  -- $(vals j8.out)"
else fail "J8 rc $rc: $(cat "$OUT/j8.out")"; fi
migl postgres j9m.log; add_pl postgres 4 "interval '366 days'" j9
rc=$(dok j9.out)
check "J9 progress log migration re-applied: the command succeeds again" "rc=$rc $(vals j9.out)" "rc=0 kodhane_save_backups=0 acik_ofis_save_backups=0 audit_log_entries=0 audit_batches=0 audit_left_over_12m=0 progress_log_rows=4 progress_log_batches=1 progress_log_left_over_365d=0 "
add_pl postgres 3 "interval '400 days'" js2
rc=$(dok js2.out "$CMD")
check "JS2 first command with the progress log present: exit 0, progress log rows untouched" "rc=$rc $(vals js2.out)$(pl_n postgres js2)" \
  "rc=0 kodhane_save_backups=0 acik_ofis_save_backups=0 audit_log_entries=0 audit_batches=0 audit_left_over_12m=0 3"
P -d template1 -c "drop database postgres with (force)" -c "alter database kr_postgres_orig rename to postgres" >/dev/null
check "J7 container's own postgres database restored" "$(PA -d postgres -c "select to_regclass('public.kodhane_saves') is null")" t
for f in js1 j1 j2 j3 j4 j5 j6 j8 j9 js2; do echo "== $f.out"; sed 's/^/   /' "$OUT/$f.out"; done

# ------------------------------------------------------------------ R: rollback
fresh kr_rb; mig kr_rb r0.log
if P -d kr_rb -f - < "$RB" > "$OUT/r1.log" 2>&1 && [[ $(fn_state kr_rb) == absent ]]; then pass "R1 rollback drops the function"; else fail "R1 $(cat "$OUT/r1.log")"; fi
dump kr_rb > "$OUT/dump_rb.sql"
if diff -q "$OUT/dump_before.sql" "$OUT/dump_rb.sql" >/dev/null; then pass "R2 public + auth schema after rollback = before the migration (diff empty)"; else fail "R2 schema diff after rollback"; fi
if P -d kr_rb -f - < "$RB" > "$OUT/r3.log" 2>&1; then pass "R3 rollback twice (idempotent)"; else fail "R3 $(cat "$OUT/r3.log")"; fi
if mig kr_rb r4.log && [[ $(fn_state kr_rb) == "postgres|true|search_path=\"\"|$ACL" ]] && P -d kr_rb -f - < "$RB" >/dev/null 2>&1 \
   && dump kr_rb | diff -q "$OUT/dump_before.sql" - >/dev/null; then pass "R4 apply -> rollback -> apply -> rollback: same ACL, schema back to before"
else fail "R4 re-apply / rollback cycle"; fi
dump kr_noperm > "$OUT/dump_noperm.sql"
r=$(dump_minus "$OUT/dump_noperm.sql" 'TABLE audit_log_entries; Type: ACL' | diff <(dump_minus "$OUT/dump_before.sql" 'TABLE audit_log_entries; Type: ACL') - | grep -cE '^[<>]')
check "R5 failed migration (M0): nothing left behind (schema diff vs before, apart from the test's own revoke / re-grant ACL)" "$(fn_state kr_noperm)|$r" "absent|0"

for d in kr_main kr_noperm kr_wrong kr_rb; do P -d postgres -c "drop database if exists $d" >/dev/null 2>&1; done
echo "== done: $PASSN pass / $FAILS fail; image $(docker inspect -f '{{.Config.Image}}' "$CT"); artefacts in $OUT"
[[ $FAILS == 0 ]]
