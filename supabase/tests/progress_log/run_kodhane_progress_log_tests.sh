#!/usr/bin/env bash
# Kodhane progress log (kazanç günlüğü, migration 20261003020000) tests. LOCAL THROWAWAY DATABASES ONLY, in the local docker
# container $PL_CT (supabase/postgres image) whose database $PL_BASE holds the live schema (v2.2, no data). Never point this
# at the live DB: it drops/creates databases, writes and deletes rows.
#   PL_CT=<container> bash supabase/tests/progress_log/run_kodhane_progress_log_tests.sh 2>&1 | tee /tmp/kd-plog-test.log
# Runs twice: variant a = base + package A + log, variant ab = base + A + B + log (B ships with the log).
# Groups: M migration, P privileges / RLS, F fields, T Borsa Payı Ağacı, E event types (telafi + approval_ref, sifirlama, geri_yukleme),
# B interaction with refused writes (v2.2 PT409, B PT426), X trigger errors are swallowed, C cleanup, R rollback.
# Account deletion of log rows: supabase/tests/account_delete/run_kodhane_account_delete_tests.sh (L-*).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CT="${PL_CT:-v44x-136}"; BASE="${PL_BASE:-v44_base}"; OUT="${PL_OUT:-/tmp/kd-plog-test}"; mkdir -p "$OUT"; chmod 700 "$OUT"
MIGA="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"; MIGB="$ROOT/migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql"
MIGL="$ROOT/migrations/20261003020000_v4_4_kodhane_progress_log.sql"; RBL="$ROOT/rollback/20261003020000_v4_4_kodhane_progress_log.rollback.sql"
U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222; U3=33333333-3333-4333-8333-333333333333
U4=44444444-4444-4444-8444-444444444444
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
PA() { P -At -F '|' "$@"; }
FAILS=0; PASSN=0; V=""
pass() { echo "PASS [$V] $*"; PASSN=$((PASSN+1)); }
fail() { echo "FAIL [$V] $*"; FAILS=$((FAILS+1)); }
check() { local name=$1 got=$2 want=$3; if [[ "$got" == "$want" ]]; then pass "$name  -- ${got:0:160}"; else fail "$name: got '$got', want '$want'"; fi; }
fresh() { P -d postgres -c "drop database if exists $1" -c "create database $1 template $BASE" >/dev/null 2>&1; }
dump() { docker exec "$CT" pg_dump -U supabase_admin --schema-only -n public "$1" | grep -v '^\\\(un\)\?restrict '; }
q() { local d=$1; shift; PA -d "$d" "$@" 2>>"$OUT/$V.stderr" | sed '/^$/d'; }
# pw <db> <uid> <json patch> [text[] of keys to drop]: one player write (PostgREST-like role authenticated)
pw() { PA -d "$1" -c "select t.login('$2')" -c "select t.kw('$3'::jsonb${4:+, $4})" > /dev/null 2> "$OUT/$V.pw.err"; }
mark() { PA -d "$1" -c "select t.setmark()" > /dev/null; }
since() { q "$1" -c "select t.since(${2:+'$2'::uuid})"; }
# st <db> <uid | anon> <sql>: SQLSTATE of <sql> run as that player (none = no error)
st() { local who="'$2'"; [[ $2 == anon ]] && who=null
  PA -d "$1" -c "select t.login($who)" -c "do \$x\$ begin $3; raise notice 'ST none'; exception when others then raise notice 'ST %', sqlstate; end \$x\$" 2>&1 | grep -oE 'ST [A-Z0-9]+$' | cut -c4-; }
rev() { q "$1" -c "select revision from public.kodhane_saves where user_id = '$2'"; }
REF="KD-TLF-2026-10-03-01"; SREF="select set_config('kodhane.progress_ref', '$REF', true)"; STEL="select set_config('kodhane.progress_event', 'telafi', true)"
# tw <db> <ref | none> <shares>: admin (supabase_admin) telafi write on U2 with that approval reference
tw() { local a=(-d "$1" -c begin -c "$STEL"); [[ $2 != none ]] && a+=(-c "select set_config('kodhane.progress_ref', '$2', true)")
  a+=(-c "update public.kodhane_saves set data = data || '{\"shares\": $3}', revision = revision + 1 where user_id = '$U2'" -c commit); PA "${a[@]}"; }
# refs <db>: approval_ref of the log rows since the mark ('-' = NULL)
refs() { q "$1" -c "select coalesce(string_agg(coalesce(approval_ref, '-'), ',' order by id), '') from public.kodhane_progress_log where id > (select id from t.mark)"; }
echo "== container $CT: $(docker inspect -f '{{.Config.Image}} {{.Image}}' "$CT" | cut -c1-90)"

V=once
fresh pl_wrong; P -d pl_wrong -c "alter table public.kodhane_saves rename to kodhane_saves_x" >/dev/null
if ! P -d pl_wrong -f - < "$MIGL" > "$OUT/m0.log" 2>&1 && grep -q 'wrong target' "$OUT/m0.log" \
   && [[ $(q pl_wrong -c "select to_regclass('public.kodhane_progress_log') is null") == t ]]; then pass "M0 wrong target (no public.kodhane_saves) -> error, nothing created"
else fail "M0 $(grep -m1 -oE 'ERROR: .*' "$OUT/m0.log")"; fi
P -d postgres -c "drop database if exists pl_wrong" >/dev/null 2>&1

suite() {   # suite <db> <variant: a | ab>
  local D=$1 r; V=$2
  echo "== [$V] setup"
  fresh $D
  P -d $D -1 -f - < "$MIGA" > /dev/null 2>&1 || { fail "M-setup A"; return; }
  if [[ $V == ab ]]; then P -d $D -1 -f - < "$MIGB" > /dev/null 2>&1 || { fail "M-setup B"; return; }; fi
  dump $D > "$OUT/$V.pre.sql"
  P -d $D -f - < "$MIGL" > "$OUT/$V.mig1.log" 2>&1 && pass "M1 migration applies (own transaction, no -1)" || { fail "M1 $(grep -m1 -oE 'ERROR: .*' "$OUT/$V.mig1.log")"; return; }
  dump $D > "$OUT/$V.post1.sql"
  P -d $D -f - < "$MIGL" > "$OUT/$V.mig2.log" 2>&1 && dump $D > "$OUT/$V.post2.sql" && diff -q "$OUT/$V.post1.sql" "$OUT/$V.post2.sql" >/dev/null \
    && pass "M2 idempotent: second run OK, schema unchanged" || fail "M2 second run / schema differs"
  check "M3 table: owner | RLS on | not forced | policies" "$(q $D -c "select c.relowner::regrole || '|' || c.relrowsecurity || '|' || c.relforcerowsecurity || '|' || (select count(*) from pg_policy p where p.polrelid = c.oid) from pg_class c where c.oid = 'public.kodhane_progress_log'::regclass")" "postgres|true|false|0"
  check "M4 trigger: AFTER INSERT OR UPDATE FOR EACH ROW, enabled; function security definer, owner postgres, search_path ''" \
    "$(q $D -c "select t.tgtype || '|' || t.tgenabled::text || '|' || p.prosecdef || '|' || p.proowner::regrole || '|' || array_to_string(p.proconfig, ',') from pg_trigger t join pg_proc p on p.oid = t.tgfoid where t.tgrelid = 'public.kodhane_saves'::regclass and t.tgname = 'kodhane_saves_z_progress_log'")" \
    '21|O|true|postgres|search_path=""'
  check "M5 columns (no e-mail / nickname column)" "$(q $D -c "select string_agg(attname, ',' order by attnum) from pg_attribute where attrelid = 'public.kodhane_progress_log'::regclass and attnum > 0 and not attisdropped")" \
    "id,user_id,rev_before,rev_after,client_version,event,field,old_value,new_value,node_id,actor_role,created_at,approval_ref"
  check "M6 approval_ref constraint (telafi <=> reference, format) and cleanup default 365 days" \
    "$(q $D -c "select (select count(*) from pg_constraint where conrelid = 'public.kodhane_progress_log'::regclass and conname = 'kodhane_progress_log_ref_chk') || '|' || pg_get_function_arguments('public.kodhane_cleanup_progress_log(integer,integer)'::regprocedure)")" \
    "1|p_retention_days integer DEFAULT 365, p_batch_size integer DEFAULT 5000"
  P -d $D -f - < "$ROOT/tests/fixtures/helpers.sql" > /dev/null && P -d $D -f - < "$HERE/fixture.sql" > /dev/null || { fail "setup fixture"; return; }
  for u in $U1 $U2 $U3; do PA -d $D -c "select t.login('$u')" -c "select t.ki(t.save0())" > /dev/null || fail "setup save $u"; done
  check "F0 first saves with every logged field at 0 (INSERT) -> no row" "$(q $D -c "select count(*) from public.kodhane_progress_log")" "0"

  echo "== [$V] P privileges / RLS"
  check "P1 anon + authenticated: no table privilege at all" "$(q $D -c "select count(*) filter (where has_table_privilege(r, 'public.kodhane_progress_log', p)) from unnest(array['anon', 'authenticated', 'public']) r, unnest(array['select', 'insert', 'update', 'delete', 'truncate', 'references', 'trigger']) p")" "0"
  check "P2 service_role: SELECT only" "$(q $D -c "select string_agg(has_table_privilege('service_role', 'public.kodhane_progress_log', p)::text, ',') from unnest(array['select', 'insert', 'update', 'delete', 'truncate']) p")" "true,false,false,false,false"
  check "P3 identity sequence: no USAGE / SELECT / UPDATE for anon, authenticated, service_role" "$(q $D -c "select count(*) filter (where has_sequence_privilege(r, pg_get_serial_sequence('public.kodhane_progress_log', 'id'), p)) from unnest(array['anon', 'authenticated', 'service_role']) r, unnest(array['usage', 'select', 'update']) p")" "0"
  check "P4 function ACLs: cleanup postgres + service_role; trigger function postgres only" "$(q $D -c "select coalesce((select proacl::text from pg_proc where oid = 'public.kodhane_cleanup_progress_log(integer,integer)'::regprocedure), '') || ' ' || coalesce((select proacl::text from pg_proc where oid = 'public.kodhane_progress_log_write()'::regprocedure), '')")" \
    "{postgres=X/postgres,service_role=X/postgres} {postgres=X/postgres}"
  r="$(st $D $U1 "perform count(*) from public.kodhane_progress_log") $(st $D $U1 "insert into public.kodhane_progress_log (user_id, event, field, actor_role) values (auth.uid(), 'telafi', 'shares', 'x')") $(st $D $U1 "update public.kodhane_progress_log set new_value = 1") $(st $D $U1 "delete from public.kodhane_progress_log") $(st $D $U1 "perform public.kodhane_cleanup_progress_log(1, 10)")"
  check "P5 authenticated: select / insert / update / delete / cleanup -> 42501" "$r" "42501 42501 42501 42501 42501"
  r="$(st $D anon "perform count(*) from public.kodhane_progress_log") $(st $D anon "insert into public.kodhane_progress_log (user_id, event, field, actor_role) values ('$U1', 'telafi', 'shares', 'x')") $(st $D anon "perform public.kodhane_cleanup_progress_log(1, 10)")"
  check "P6 anon: select / insert / cleanup -> 42501" "$r" "42501 42501 42501"
  pw $D $U1 '{"shares": 1}'
  r=$(q $D -c "begin" -c "grant select on public.kodhane_progress_log to authenticated" -c "select t.login('$U1')" -c "select count(*) from public.kodhane_progress_log" -c "rollback" | tail -n 1)
  check "P7 RLS without policy: even a mistaken GRANT SELECT shows a player 0 rows (own row exists)" "$r" "0"

  echo "== [$V] F fields"
  local f ev
  for f in shares prestigeCount cycleRounds ipoCount ipoShares ipoSharesEarned; do
    case $f in ipoCount) ev=halka_arz;; ipoShares|ipoSharesEarned) ev=borsa_payi;; *) ev=yatirim_turu;; esac
    pw $D $U2 "{\"$f\": 0}"; mark $D; pw $D $U2 "{\"$f\": 3}"; r=$(since $D)
    pw $D $U2 "{\"$f\": 1}"; r="$r / $(since $D | sed "s/^$ev:$f:0>3 //")"
    check "F1 $f: increase 0 -> 3 and decrease 3 -> 1, one row each, event $ev" "$r" "$ev:$f:0>3 / $ev:$f:3>1"
  done
  pw $D $U2 '{"ipoCount": 2}'; mark $D; pw $D $U2 '{"ipoCount": 0}'; check "F2 decrease ipoCount 2 -> 0 is logged" "$(since $D)" "halka_arz:ipoCount:2>0"
  mark $D; pw $D $U2 '{"totalEarned": 99999, "money": 77, "runEarned": 5000, "cycleEarned": 5000}'
  check "F3 write that changes no logged field (totalEarned, money ...) -> no row" "$(since $D)" ""
  mark $D; pw $D $U2 '{"shares": 1, "prestigeCount": 1, "ipoShares": 1}'; check "F4 same values written again -> no row" "$(since $D)" ""
  pw $D $U2 '{"cycleRounds": 0}'; mark $D; pw $D $U2 '{}' "array['cycleRounds']"; r=$(since $D); pw $D $U2 '{"cycleRounds": 0}'; r="$r|$(since $D)"
  check "F5 0 -> missing and missing -> 0: no row (missing counts as 0)" "$r" "|"
  pw $D $U2 '{"prestigeCount": 0}'; mark $D; pw $D $U2 '{"prestigeCount": "abc"}'; r=$(since $D); pw $D $U2 '{"prestigeCount": 5}'; pw $D $U2 '{"prestigeCount": "x"}'
  check "F6 non-number: '0' -> 'abc' no row; 'abc' -> 5 logged as -/5; 5 -> 'x' logged as 5 -> NULL" "$r|$(since $D)" "|yatirim_turu:prestigeCount:->5 yatirim_turu:prestigeCount:5>-"
  local rb; rb=$(rev $D $U2); mark $D; pw $D $U2 '{"shares": 9}'
  check "F7 rev_before / rev_after = save revision before / after; client_version from saveVersion" \
    "$(q $D -c "select rev_before || '>' || rev_after || '|' || client_version || '|' || actor_role from public.kodhane_progress_log order by id desc limit 1")" "$rb>$((rb+1))|saveVersion 5|authenticated"
  pw $D $U2 '{"shares": 10, "clientVersion": "4.4.1"}'; pw $D $U2 '{"shares": 11, "clientVersion": "1234567890123456789012345678901234567890"}'
  check "F8 data.clientVersion (string) is used when the client sends it; longer than 32 characters -> NULL" \
    "$(q $D -c "select string_agg(coalesce(client_version, '-'), ',' order by id) from (select id, client_version from public.kodhane_progress_log order by id desc limit 2) x")" "4.4.1,-"
  mark $D; local cv
  for cv in '"4.4.1 beta"' '"<script>"' '""' '5' '["4.4"]' '"4.4.2-rc.1_b"' 'null'; do pw $D $U2 "{\"shares\": $(( $(q $D -c "select (data->>'shares')::int from public.kodhane_saves where user_id = '$U2'") + 1 )), \"clientVersion\": $cv}"; done
  pw $D $U2 '{"shares": 30}' "array['clientVersion']"
  check "F8b clientVersion: space / <> / empty / number / array -> NULL; [0-9A-Za-z._-] kept; JSON null and missing -> saveVersion fallback" \
    "$(q $D -c "select string_agg(coalesce(client_version, '-'), ',' order by id) from public.kodhane_progress_log where id > (select id from t.mark)")" "-,-,-,-,-,4.4.2-rc.1_b,saveVersion 5,saveVersion 5"
  pw $D $U2 '{"shares": 11}'
  PA -d $D -c "select t.login('$U4')" -c "select t.ki(t.save0() || '{\"shares\": 7, \"ipoCount\": 1, \"tree\": [\"kod_1\"]}')" > /dev/null
  check "F9 first insert with values: one row per non-zero field, rev_before NULL" \
    "$(q $D -c "select t.since('$U4') || ' rev ' || coalesce(min(rev_before)::text, 'null') || '>' || min(rev_after) from public.kodhane_progress_log where user_id = '$U4'")" \
    "yatirim_turu:shares:->7 halka_arz:ipoCount:->1 agac:tree:0>1:kod_1 rev null>1"
  pw $D $U3 '{"shares": 1, "prestigeCount": 4, "cycleRounds": 4}'; mark $D
  pw $D $U3 '{"cycleRounds": 0, "ipoCount": 1, "ipoShares": 3, "ipoSharesEarned": 3}'
  check "F10 Halka Arz in one write: four rows, one per changed field, shares kept -> no row" "$(since $D)" \
    "yatirim_turu:cycleRounds:4>0 halka_arz:ipoCount:0>1 borsa_payi:ipoShares:0>3 borsa_payi:ipoSharesEarned:0>3"
  mark $D; P -d $D -c "update public.kodhane_saves set revision = revision + 1, updated_at = now() where user_id = '$U3'" > /dev/null
  check "F11 update without a data change (revision / updated_at only) -> no row" "$(since $D)" ""

  echo "== [$V] T Borsa Payı Ağacı (data.tree)"
  mark $D; pw $D $U3 '{"ipoShares": 2, "tree": ["kod_1"]}'; check "T1 buyNode: ipoShares 3 -> 2 + node kod_1" "$(since $D)" "borsa_payi:ipoShares:3>2 agac:tree:0>1:kod_1"
  mark $D; pw $D $U3 '{"tree": ["kod_1", "ekip_1", "kod_2"]}'; check "T2 two nodes in one write: one row each, array order, old/new = node counts" "$(since $D)" "agac:tree:1>3:ekip_1 agac:tree:1>3:kod_2"
  mark $D; pw $D $U3 '{"tree": ["kod_1"]}'; check "T3 removed nodes (overwrite by an older state) are logged too" "$(since $D)" "agac:tree:3>1:ekip_1 agac:tree:3>1:kod_2"
  mark $D; pw $D $U3 '{"tree": ["kod_1", 5, {"a": 1}, "kod_1", "DROP TABLE x", "a_123", "<script>", "yatirim_3", null]}'
  check "T4 only node-like strings count (numbers, objects, junk, duplicates ignored)" "$(since $D)" "agac:tree:1>2:yatirim_3"
  mark $D; P -d $D -c "select t.login('$U3')" -c "select t.kw(jsonb_build_object('tree', '[\"kod_1\", \"yatirim_3\"]'::jsonb || (select jsonb_agg('x' || g || '_1') from generate_series(1, 1000) g)))" > /dev/null
  check "T5 1000 new node ids in one write: at most 64 distinct ids are read (62 rows)" "$(q $D -c "select count(*) || '|' || max(new_value) from public.kodhane_progress_log where id > (select id from t.mark)")" "62|64"
  pw $D $U3 '{"tree": ["kod_1"]}'; mark $D; pw $D $U3 '{"tree": "kod_2"}'; check "T6 tree not an array -> treated as empty (removal of kod_1)" "$(since $D)" "agac:tree:1>0:kod_1"

  echo "== [$V] E event types"
  mark $D; q $D -c "begin" -c "$STEL" -c "$SREF" -c "update public.kodhane_saves set data = data || '{\"shares\": 40, \"ipoCount\": 5}', revision = revision + 1 where user_id = '$U2'" -c "commit" > /dev/null
  check "E1 telafi: supabase_admin + kodhane.progress_event = telafi + kodhane.progress_ref -> approval_ref on every row" "$(since $D)|$(q $D -c "select string_agg(distinct actor_role, ',') from public.kodhane_progress_log where id > (select id from t.mark)")|$(refs $D)" "telafi:shares:11>40 telafi:ipoCount:0>5|supabase_admin|$REF,$REF"
  mark $D; q $D -c "begin" -c "set local role service_role" -c "$STEL" -c "$SREF" -c "update public.kodhane_saves set data = data || '{\"shares\": 41}', revision = revision + 1 where user_id = '$U2'" -c "commit" > /dev/null
  check "E2 telafi as service_role (v4.5 restore path)" "$(since $D)|$(q $D -c "select actor_role from public.kodhane_progress_log order by id desc limit 1")" "telafi:shares:40>41|service_role"
  mark $D; q $D -c "begin" -c "set local role postgres" -c "$STEL" -c "$SREF" -c "update public.kodhane_saves set data = data || '{\"shares\": 42}', revision = revision + 1 where user_id = '$U2'" -c "commit" > /dev/null
  check "E3 telafi as postgres (Dokploy / manual SQL)" "$(since $D)|$(q $D -c "select actor_role from public.kodhane_progress_log order by id desc limit 1")" "telafi:shares:41>42|postgres"
  mark $D; q $D -c "update public.kodhane_saves set data = data || '{\"shares\": 43}', revision = revision + 1 where user_id = '$U2'" > /dev/null
  check "E4 admin write WITHOUT the setting -> field event, actor recorded" "$(since $D)|$(q $D -c "select actor_role from public.kodhane_progress_log order by id desc limit 1")" "yatirim_turu:shares:42>43|supabase_admin"
  mark $D; PA -d $D -c "select t.login('$U2')" -c "select set_config('kodhane.progress_event', 'telafi', false)" -c "select t.kw('{\"shares\": 44}')" > /dev/null
  check "E5 player sets kodhane.progress_event = telafi itself -> NOT telafi (role authenticated)" "$(since $D)|$(q $D -c "select actor_role from public.kodhane_progress_log order by id desc limit 1")" "yatirim_turu:shares:43>44|authenticated"
  mark $D; PA -d $D -c "select t.login('$U2')" -c "select set_config('kodhane.progress_event', 'telafi', false)" -c "select public.kodhane_reset_save()" > /dev/null
  r=$(since $D)
  check "E7 player + setting + SECURITY DEFINER RPC (kodhane_reset_save) -> sifirlama, not telafi; every field back to 0" "$r" \
    "sifirlama:shares:44>0 sifirlama:ipoCount:5>0 sifirlama:ipoShares:1>0 sifirlama:ipoSharesEarned:1>0"
  local bid; bid=$(q $D -c "select id from public.kodhane_save_backups where user_id = '$U2' and reason = 'reset' order by created_at desc limit 1")
  mark $D; PA -d $D -c "select t.login('$U2')" -c "select public.kodhane_restore_save('$bid')" > /dev/null
  check "E8 kodhane_restore_save -> geri_yukleme" "$(since $D)" "geri_yukleme:shares:0>44 geri_yukleme:ipoCount:0>5 geri_yukleme:ipoShares:0>1 geri_yukleme:ipoSharesEarned:0>1"
  mark $D; pw $D $U2 '{"shares": 45}'; check "E9 the next normal write (new transaction) is a normal field event again" "$(since $D)" "yatirim_turu:shares:44>45"
  mark $D; for v in TELAFI ' telafi' 'telafi;' yes; do q $D -c "begin" -c "select set_config('kodhane.progress_event', '$v', true)" -c "update public.kodhane_saves set data = data || jsonb_build_object('shares', (data->>'shares')::int + 1), revision = revision + 1 where user_id = '$U2'" -c "commit" > /dev/null; done
  check "E10 other values of the setting ('TELAFI', ' telafi', 'telafi;', 'yes') -> not telafi" "$(since $D)" "yatirim_turu:shares:45>46 yatirim_turu:shares:46>47 yatirim_turu:shares:47>48 yatirim_turu:shares:48>49"
  mark $D; q $D -c "begin" -c "$STEL" -c "$SREF" -c "update public.kodhane_saves set data = data || '{\"shares\": 60}', revision = revision + 1 where user_id = '$U2'" -c "commit" \
    -c "update public.kodhane_saves set data = data || '{\"shares\": 61}', revision = revision + 1 where user_id = '$U2'" > /dev/null
  check "E11 set_config(..., true) ends with its transaction (same session, next write is not telafi, no reference)" "$(since $D)|$(refs $D)" "telafi:shares:49>60 yatirim_turu:shares:60>61|$REF,-"
  # E12-E16: approval reference (kodhane.progress_ref)
  local s0 bad e12=""; s0=$(q $D -c "select md5(data::text) || revision from public.kodhane_saves where user_id = '$U2'"); mark $D
  for bad in none "" "KD-TLF-2026-13-01-01" "kd-tlf-2026-10-03-01" "KD-TLF-2026-02-31-01" "KD-TLF-2026-10-03-1" "KD-TLF-2026-10-03-01; x" " KD-TLF-2026-10-03-01" "TLF-2026-10-03-01"; do
    tw $D "$bad" 70 > /dev/null 2> "$OUT/$V.e12.err"
    e12="$e12 $(grep -c 'telafi write refused: kodhane.progress_ref must be an approval reference' "$OUT/$V.e12.err")"
  done
  check "E12 telafi flag without a valid reference (none, empty, month 13, lower case, 2026-02-31, NN 1 digit, suffix, space, prefix) -> write refused (22023), not swallowed" \
    "$e12|$(since $D)|$(q $D -c "select md5(data::text) || revision from public.kodhane_saves where user_id = '$U2'")" " 1 1 1 1 1 1 1 1 1||$s0"
  check "E13 the refusal is SQLSTATE 22023 (no WARNING-and-keep)" "$(PA -d $D -c "do \$x\$ begin perform set_config('kodhane.progress_event', 'telafi', true); update public.kodhane_saves set data = data || '{\"shares\": 71}', revision = revision + 1 where user_id = '$U2'; raise notice 'ST none'; exception when others then raise notice 'ST %', sqlstate; end \$x\$" 2>&1 | grep -oE 'ST [A-Z0-9]+$' | cut -c4-)" "22023"
  mark $D; q $D -c "begin" -c "$SREF" -c "update public.kodhane_saves set data = data || '{\"shares\": 72}', revision = revision + 1 where user_id = '$U2'" -c "commit" > /dev/null
  check "E14 reference without the telafi flag (admin) -> field event, approval_ref NULL" "$(since $D)|$(refs $D)" "yatirim_turu:shares:61>72|-"
  mark $D; PA -d $D -c "select t.login('$U2')" -c "select set_config('kodhane.progress_event', 'telafi', false)" -c "select set_config('kodhane.progress_ref', '$REF', false)" -c "select t.kw('{\"shares\": 73}')" > /dev/null 2> "$OUT/$V.e15.err"
  check "E15 player sets flag + reference itself -> write accepted as a normal player write, NOT telafi, approval_ref NULL" "$(since $D)|$(refs $D)|$(grep -c refused "$OUT/$V.e15.err")" "yatirim_turu:shares:72>73|-|0"
  check "E16 table rule: approval_ref set exactly on telafi rows, all in KD-TLF format" \
    "$(q $D -c "select count(*) filter (where (event = 'telafi') <> (approval_ref is not null)) || '/' || count(*) filter (where approval_ref is not null and approval_ref !~ '^KD-TLF-') || '/' || count(*) filter (where event = 'telafi') from public.kodhane_progress_log")" "0/0/5"
  r=$(PA -d $D -c "do \$x\$ begin insert into public.kodhane_progress_log (user_id, event, field, actor_role) values ('$U2', 'telafi', 'shares', 'x'); raise notice 'ST none'; exception when others then raise notice 'ST %', sqlstate; end \$x\$" 2>&1 | grep -oE 'ST [A-Z0-9]+$' | cut -c4-)
  r="$r $(PA -d $D -c "do \$x\$ begin insert into public.kodhane_progress_log (user_id, event, field, actor_role, approval_ref) values ('$U2', 'yatirim_turu', 'shares', 'x', '$REF'); raise notice 'ST none'; exception when others then raise notice 'ST %', sqlstate; end \$x\$" 2>&1 | grep -oE 'ST [A-Z0-9]+$' | cut -c4-)"
  check "E17 CHECK constraint: telafi row without reference / reference on a non-telafi row -> 23514 (even for an admin insert)" "$r" "23514 23514"

  echo "== [$V] B refused writes"
  local before after
  before=$(q $D -c "select md5(data::text) || revision from public.kodhane_saves where user_id = '$U1'")
  mark $D; PA -d $D -c "select t.login('$U1')" -c "update public.kodhane_saves set data = data || '{\"shares\": 99}' where user_id = auth.uid()" > /dev/null 2> "$OUT/$V.b1.err"
  check "B1 v2.2 refuses a write without a new revision on a strict row (PT409 stale_revision) -> no log row, save unchanged" \
    "$(grep -oE 'stale_revision' "$OUT/$V.b1.err" | head -1)|$(since $D)|$(q $D -c "select md5(data::text) || revision from public.kodhane_saves where user_id = '$U1'")" "stale_revision||$before"
  mark $D; pw $D $U1 '{"shares": 5, "saveVersion": 4, "version": 4}'
  if [[ $V == ab ]]; then
    check "B2 B refuses an older client's write (PT426 save_version_too_old) -> no log row, save unchanged" \
      "$(grep -oE 'save_version_too_old' "$OUT/$V.pw.err" | head -1)|$(since $D)|$(q $D -c "select md5(data::text) || revision from public.kodhane_saves where user_id = '$U1'")" "save_version_too_old||$before"
    mark $D; pw $D $U1 '{"shares": 6}'; check "B3 B accepts a v4.4 write -> logged" "$(since $D)" "yatirim_turu:shares:1>6"
  else
    check "B2 without B the same older-format write is accepted and logged (A only)" "$(since $D)|$(q $D -c "select client_version from public.kodhane_progress_log order by id desc limit 1")" "yatirim_turu:shares:1>5|saveVersion 4"
    mark $D; pw $D $U1 '{"shares": 6, "saveVersion": 5, "version": 5}'; check "B3 next v4.4 write logged" "$(since $D)" "yatirim_turu:shares:5>6"
  fi
  mark $D; PA -d $D -c "select t.login('$U1')" -c "update public.kodhane_saves set data = data || '{\"shares\": 98}', revision = 1 where user_id = auth.uid()" > /dev/null 2> "$OUT/$V.b4.err"
  check "B4 lower revision (PT409) -> no log row" "$(grep -c stale_revision "$OUT/$V.b4.err")|$(since $D)" "1|"

  echo "== [$V] X trigger errors are swallowed"
  P -d $D -c "alter table public.kodhane_progress_log add constraint t_boom check (false) not valid" > /dev/null
  rb=$(rev $D $U1); mark $D
  if pw $D $U1 '{"shares": 7}'; then r=ok; else r=error; fi
  check "X1 log insert fails (injected CHECK) -> save write succeeds, WARNING, no row" \
    "$r|$(grep -c 'WARNING:  kodhane_progress_log: not logged for this save write (SQLSTATE 23514' "$OUT/$V.pw.err")|$(since $D)|$(q $D -c "select revision || '/' || (data->>'shares') from public.kodhane_saves where user_id = '$U1'")" "ok|1||$((rb+1))/7"
  if [[ $V == ab ]]; then
    mark $D; pw $D $U1 '{"shares": 8, "saveVersion": 4}'; check "X2 a refusing BEFORE trigger is not swallowed (B PT426 still refuses while the log fails)" "$(grep -c save_version_too_old "$OUT/$V.pw.err")|$(q $D -c "select data->>'shares' from public.kodhane_saves where user_id = '$U1'")" "1|7"
  else
    mark $D; PA -d $D -c "select t.login('$U1')" -c "update public.kodhane_saves set data = data || '{\"shares\": 8}' where user_id = auth.uid()" > /dev/null 2> "$OUT/$V.x2.err"
    check "X2 a refusing BEFORE trigger is not swallowed (v2.2 PT409 still refuses while the log fails)" "$(grep -c stale_revision "$OUT/$V.x2.err")|$(q $D -c "select data->>'shares' from public.kodhane_saves where user_id = '$U1'")" "1|7"
  fi
  local sx; sx=$(q $D -c "select md5(data::text) || revision from public.kodhane_saves where user_id = '$U1'")
  PA -d $D -c "begin" -c "$STEL" -c "$SREF" -c "update public.kodhane_saves set data = data || '{\"shares\": 50}', revision = revision + 1 where user_id = '$U1'" -c "commit" > /dev/null 2> "$OUT/$V.x5.err"
  check "X5 telafi write while the log insert fails -> NOT swallowed: write refused (23514), save unchanged" \
    "$(grep -c 'violates check constraint "t_boom"' "$OUT/$V.x5.err")|$(grep -c 'not logged for this save write' "$OUT/$V.x5.err")|$(q $D -c "select md5(data::text) || revision from public.kodhane_saves where user_id = '$U1'")" "1|0|$sx"
  P -d $D -c "alter table public.kodhane_progress_log drop constraint t_boom" -c "revoke insert on public.kodhane_progress_log from postgres" > /dev/null
  mark $D; if pw $D $U1 '{"shares": 9}'; then r=ok; else r=error; fi
  check "X3 log owner without INSERT (42501) -> save write succeeds, WARNING, no row" "$r|$(grep -c 'SQLSTATE 42501' "$OUT/$V.pw.err")|$(since $D)" "ok|1|"
  P -d $D -c "grant insert on public.kodhane_progress_log to postgres" > /dev/null
  mark $D; pw $D $U1 '{"shares": 10}'; check "X4 logging resumes after the failure is fixed" "$(since $D)" "yatirim_turu:shares:9>10"

  echo "== [$V] C cleanup (365 days by default, Aryen 2026-10-03)"
  local n0; n0=$(q $D -c "select count(*) from public.kodhane_progress_log")
  r=""; for a in "null, 10" "0, 10" "-1, 10" "3651, 10" "30, null" "30, 0" "30, 50001"; do r="$r $(PA -d $D -c "do \$x\$ begin perform public.kodhane_cleanup_progress_log($a); raise notice 'ST none'; exception when others then raise notice 'ST %', sqlstate; end \$x\$" 2>&1 | grep -oE 'ST [A-Z0-9]+$' | cut -c4-)"; done
  check "C1 bad parameters (days null/0/-1/3651, batch null/0/50001) -> 22023, nothing deleted" "$r|$(q $D -c "select count(*) from public.kodhane_progress_log")" " 22023 22023 22023 22023 22023 22023 22023|$n0"
  q $D -c "insert into public.kodhane_progress_log (user_id, event, field, old_value, new_value, actor_role, created_at)
           select '$U4'::uuid, 'yatirim_turu', 'shares', g, g + 1, 'test', now() - interval '40 days' - make_interval(mins => g) from generate_series(1, 25) g
           union all select '$U4'::uuid, 'yatirim_turu', 'shares', 100 + g, 101 + g, 'test', now() - interval '10 days' from generate_series(1, 3) g" > /dev/null
  r=$(q $D -c "select public.kodhane_cleanup_progress_log(30, 10)" -c "select max(old_value) from public.kodhane_progress_log where created_at < now() - interval '30 days'" \
         -c "select public.kodhane_cleanup_progress_log(30, 10)" -c "select public.kodhane_cleanup_progress_log(30, 10)" -c "select public.kodhane_cleanup_progress_log(30, 10)" | tr '\n' ' ')
  check "C2 batches of 10: 10, (oldest first: max g left 15), 10, 5, 0" "$r" "10 15 10 5 0 "
  check "C3 rows younger than the retention and the real log rows stay" "$(q $D -c "select count(*) from public.kodhane_progress_log")" "$((n0 + 3))"
  r=$(q $D -c "begin" -c "insert into public.kodhane_progress_log (user_id, event, field, actor_role, created_at) values ('$U4', 'yatirim_turu', 'shares', 'b1', now() - interval '30 days'), ('$U4', 'yatirim_turu', 'shares', 'b2', now() - interval '30 days' - interval '1 microsecond'), ('$U4', 'yatirim_turu', 'shares', 'b3', now() - interval '30 days' + interval '1 microsecond')" \
      -c "select public.kodhane_cleanup_progress_log(30, 100)" -c "select string_agg(actor_role, ',' order by actor_role) from public.kodhane_progress_log where actor_role like 'b_'" -c "rollback" | tr '\n' ' ')
  check "C4 boundary: only rows strictly older than now() - 30 days go (exactly 30 days stays)" "$r" "1 b1,b3 "
  r=$(q $D -c "begin" -c "insert into public.kodhane_progress_log (user_id, event, field, actor_role, created_at) values ('$U4', 'yatirim_turu', 'shares', 'd366', now() - interval '366 days'), ('$U4', 'yatirim_turu', 'shares', 'd364', now() - interval '364 days')" \
      -c "select public.kodhane_cleanup_progress_log()" -c "select string_agg(actor_role, ',') from public.kodhane_progress_log where actor_role like 'd36_'" -c "rollback" | tr '\n' ' ')
  check "C6 default (no argument): 365 days, 5000 per batch -> the 366-day row goes, the 364-day row stays" "$r" "1 d364 "
  check "C5 service_role may run it; authenticated / anon may not" "$(q $D -c "begin" -c "set local role service_role" -c "select public.kodhane_cleanup_progress_log(30, 10)" -c "commit")|$(st $D $U1 "perform public.kodhane_cleanup_progress_log(30, 10)")|$(st $D anon "perform public.kodhane_cleanup_progress_log(30, 10)")" "0|42501|42501"

  echo "== [$V] R rollback"
  if P -d $D -f - < "$RBL" > "$OUT/$V.rb0.log" 2>&1; then r=ran; else r=refused; fi
  check "R1 rollback with rows and without confirmation -> refused, nothing dropped" "$r|$(grep -oE 'the table has [0-9]+ row\(s\) that would be lost' "$OUT/$V.rb0.log" | sed 's/[0-9]\+/N/')|$(q $D -c "select (to_regclass('public.kodhane_progress_log') is not null) || '/' || exists (select 1 from pg_trigger where tgname = 'kodhane_saves_z_progress_log')")" "refused|the table has N row(s) that would be lost|true/true"
  docker exec -i -e PGOPTIONS='-c kodhane.progress_log_allow_loss=on' "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 -d $D -f - < "$RBL" > "$OUT/$V.rb1.log" 2>&1 \
    && docker exec -i -e PGOPTIONS='-c kodhane.progress_log_allow_loss=on' "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 -d $D -f - < "$RBL" > "$OUT/$V.rb2.log" 2>&1 \
    && dump $D > "$OUT/$V.after_rb.sql" && diff -q "$OUT/$V.pre.sql" "$OUT/$V.after_rb.sql" >/dev/null \
    && pass "R2 rollback with kodhane.progress_log_allow_loss=on (twice): public schema = before the migration" || fail "R2 rollback: $(grep -m1 -oE 'ERROR: .*' "$OUT/$V.rb1.log" "$OUT/$V.rb2.log"); diff $(diff "$OUT/$V.pre.sql" "$OUT/$V.after_rb.sql" | wc -l) lines"
  if pw $D $U1 '{"shares": 11}'; then pass "R3 save writes work after the rollback"; else fail "R3 write after rollback: $(head -c 200 "$OUT/$V.pw.err")"; fi
  P -d $D -f - < "$MIGL" > /dev/null 2>&1 && dump $D > "$OUT/$V.post3.sql" && diff -q "$OUT/$V.post1.sql" "$OUT/$V.post3.sql" >/dev/null \
    && pass "R4 re-apply after rollback: same schema as the first apply" || fail "R4 re-apply"
  P -d postgres -c "drop database if exists $D" > /dev/null 2>&1
}

suite pl_a a
suite pl_ab ab
V=all
echo "== done: $PASSN pass / $FAILS fail; image $(docker inspect "$CT" --format '{{.Config.Image}}'); artefacts in $OUT"
[[ $FAILS == 0 ]]
