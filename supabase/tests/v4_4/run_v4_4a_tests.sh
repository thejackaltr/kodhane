#!/usr/bin/env bash
# Package A (kodhane_score_plausible v4.4a) tests. LOCAL THROWAWAY DATABASES ONLY, in the local docker container
# $V44_CT (supabase/postgres 17.6 image) whose database $V44_BASE holds the live public schema after v2.2 (pg_dump
# --schema-only of the live DB, no data). Never point this at supabase.teserix.com: it drops/creates databases.
#   bash supabase/tests/v4_4/run_v4_4a_tests.sh 2>&1 | tee /tmp/v44a-test.log
# Optional inputs (not in git): $V44_LIVE_COPY (pseudonymized read-only copy of the live saves, loader SQL) and
# $V44_FIK (anonymous copy of the compensated save). Without them the fixture fixtures/v4_4a_compensated_save.json is used
# and the live dry-run test (L1) is skipped. Sim snapshots: $V44_SIM/*.jsonl (sim_saves.cjs output).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CT="${V44_CT:-v44db}"; BASE="${V44_BASE:-v44_base}"; DB=v44a_test; DB2=v44a_roundtrip; DB3=v44a_guard
MIG="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"
RB="$ROOT/rollback/20260929203000_v4_4a_kodhane_score_plausible.rollback.sql"
PRE="$ROOT/ops/v4_4a_preflight.sql"; VER="$ROOT/ops/v4_4a_verify.sql"
LIVE="${V44_LIVE_COPY:-/workspace/tmp/v44/a/live_copy.sql}"; FIK="${V44_FIK:-/workspace/tmp/v44/a/fik_copy.json}"
SIM="${V44_SIM:-/workspace/tmp/v44/sim}"; HONEST="${KODHANE_CLOUD:-/workspace/kodhane-cloud}/honest_sims.json"
OUT="${V44_OUT:-/tmp/v44a-test}"; mkdir -p "$OUT"; chmod 700 "$OUT"
FIKUID=f1c0f1c0-0000-4000-8000-00000000f1c0
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
PA() { P -At "$@"; }
dump() { docker exec "$CT" pg_dump -U supabase_admin --schema-only -n public "$1" | grep -v '^\\\(un\)\?restrict '; }   # \restrict key is random per dump
fdefs() { PA -d "$1" -c "select p.oid::regprocedure, md5(pg_get_functiondef(p.oid)), p.proacl, coalesce(obj_description(p.oid,'pg_proc'),'')
  from pg_proc p where p.pronamespace = 'public'::regnamespace order by 1"; }
ao_state() { PA -d "$1" -c "select 'data', md5(string_agg(t::text, '|' order by t::text)) from (select * from public.acik_ofis_saves) t
  union all select 'lb', md5(coalesce(string_agg(l::text, '|'), '')) from public.kodhane_leaderboard(100, 'acik_ofis') l
  union all select 'funcs', md5(string_agg(pg_get_functiondef(oid) || coalesce(proacl::text,''), '|' order by oid::regprocedure::text))
    from pg_proc where pronamespace = 'public'::regnamespace and proname like 'acik_ofis%'"; }
fresh() { P -d postgres -c "drop database if exists $1" -c "create database $1 template $BASE"; }
FAILS=0; PASSN=0; pass() { echo "PASS $*"; PASSN=$((PASSN+1)); }; fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
same() { if diff -u "$2" "$3" > "$OUT/$1.diff"; then pass "$1 (diff empty)"; else fail "$1: $(wc -l < "$OUT/$1.diff") diff lines, see $OUT/$1.diff"; fi; }

echo "== 0. preflight/function body identical"
python3 - "$MIG" "$PRE" <<'PY' && pass "P0 preflight inlines the migration body byte-for-byte (3x)" || fail "P0 preflight body differs from migration"
import sys
m = open(sys.argv[1]).read().split('-- <v4_4a_body>\n')[1].split('\n-- </v4_4a_body>')[0]
parts = open(sys.argv[2]).read().split('      -- <v4_4a_body>\n')[1:]
bodies = ['\n'.join(l[6:] if l.startswith('      ') else l for l in p.split('\n      -- </v4_4a_body>')[0].split('\n')) for p in parts]
sys.exit(0 if len(bodies) == 3 and all(b == m for b in bodies) else 1)
PY

echo "== 1. A alone on the post-v2.2 live schema: apply, rollback, schema diff"
fresh $DB2; dump $DB2 > "$OUT/rt_pre.sql"; fdefs $DB2 > "$OUT/rt_pre.fdefs"
P -d $DB2 -1 -f - < "$MIG" 2>&1 | sed 's/^/   /'; P -d $DB2 -1 -f - < "$MIG" 2>&1 | sed 's/^/   /'
dump $DB2 > "$OUT/rt_mid.sql"; fdefs $DB2 > "$OUT/rt_mid.fdefs"
n=$(diff "$OUT/rt_pre.fdefs" "$OUT/rt_mid.fdefs" | grep -c '^[<>]' || true)
[[ "$(diff "$OUT/rt_pre.fdefs" "$OUT/rt_mid.fdefs" | grep '^[<>]' | cut -d'|' -f1 | sort -u)" == "$(printf '< kodhane_score_plausible(jsonb,timestamp with time zone)\n> kodhane_score_plausible(jsonb,timestamp with time zone)')" ]] \
  && pass "R1 A changes exactly one object: kodhane_score_plausible ($n fdef lines)" || fail "R1 A changed more than kodhane_score_plausible"
P -d $DB2 -At -F '|' -f - < "$VER" > "$OUT/verify.txt"; grep -q '|f$' "$OUT/verify.txt" && fail "R2 verify has failing checks" || pass "R2 ops/v4_4a_verify.sql all t ($(grep -c '|t$' "$OUT/verify.txt") checks)"
P -d $DB2 -1 -f - < "$RB" 2>&1 | sed 's/^/   /'; P -d $DB2 -1 -f - < "$RB" 2>&1 | sed 's/^/   /'
dump $DB2 > "$OUT/rt_post.sql"; fdefs $DB2 > "$OUT/rt_post.fdefs"
same R3_schema_after_rollback "$OUT/rt_pre.sql" "$OUT/rt_post.sql"
same R4_fdefs_acl_comments_after_rollback "$OUT/rt_pre.fdefs" "$OUT/rt_post.fdefs"
P -d $DB2 -1 -f - < "$MIG" >/dev/null 2>&1; dump $DB2 > "$OUT/rt_again.sql"; same R5_reapply_after_rollback "$OUT/rt_mid.sql" "$OUT/rt_again.sql"

echo "== 2. guards"
fresh $DB3; P -d $DB3 -c "alter table public.kodhane_saves rename column best_score to best_score_pre_v22"   # = schema without v2.2
if P -d $DB3 -1 -f - < "$MIG" > "$OUT/g1.txt" 2>&1; then fail "G1 A applied without v2.2"; else grep -q 'v2.2 (20260928160000) is not applied' "$OUT/g1.txt" && pass "G1 A refuses without Kodhane v2.2" || fail "G1 wrong error: $(tail -1 "$OUT/g1.txt")"; fi
fresh $DB3; P -d $DB3 -c "create or replace function public.kodhane_score_plausible(d jsonb, p_now timestamptz default now()) returns boolean language sql stable parallel safe set search_path to '' as \$\$ select true \$\$"
if P -d $DB3 -1 -f - < "$MIG" > "$OUT/g2.txt" 2>&1; then fail "G2 A overwrote an unknown definition"; else grep -q 'unexpected kodhane_score_plausible definition' "$OUT/g2.txt" && pass "G2 A refuses to overwrite an unexpected definition" || fail "G2 wrong error"; fi
if P -d $DB3 -1 -f - < "$RB" > "$OUT/g3.txt" 2>&1; then fail "G3 rollback overwrote an unknown definition"; else pass "G3 rollback refuses on an unexpected definition"; fi
P -d postgres -c "drop database $DB3"

echo "== 3. full test DB: live copy + sims, before/after"
fresh $DB; dump $DB > "$OUT/pre.sql"; fdefs $DB > "$OUT/pre.fdefs"
P -d $DB -f - < "$ROOT/tests/fixtures/helpers.sql" >/dev/null
sed 's/FUNCTION public.kodhane_score_plausible(/FUNCTION t.plaus_v43(/' <(awk '/^CREATE OR REPLACE FUNCTION public.kodhane_score_plausible/,/^end \$function\$/' "$RB") | P -d $DB -f - >/dev/null
echo ';' | P -d $DB >/dev/null
HAVE_LIVE=0; if [[ -r "$LIVE" ]]; then P -d $DB -f - < "$LIVE" >/dev/null; HAVE_LIVE=1; fi
[[ -r "$FIK" ]] || FIK="$ROOT/tests/fixtures/v4_4a_compensated_save.json"
python3 - "$FIK" "$FIKUID" "$HONEST" > "$OUT/extra.sql" <<'PY'
import json, sys
q = lambda s: "'" + str(s).replace("'", "''") + "'"
f = json.load(open(sys.argv[1])); u = sys.argv[2]
print("set session_replication_role = replica;")
print("insert into auth.users (id, aud, role) values (%s, 'authenticated', 'authenticated');" % q(u))
print("insert into public.kodhane_profiles (user_id, nickname) values (%s, 'Anonim Telafi');" % q(u))
print("insert into public.kodhane_saves (user_id, data, save_version, updated_at, best_score, revision, strict_revision, best_stage) values (%s, %s::jsonb, %d, now() - interval '10 minutes', %r, %d, %s, %d);"
      % (q(u), q(json.dumps(f['data'])), f['save_version'], f['best_score'], f['revision'], 'true' if f['strict_revision'] else 'false', f['best_stage']))
print("set session_replication_role = origin;")
print("create table t.fik as select * from public.kodhane_saves where user_id = %s;" % q(u))
print("create table t.honest (name text, now_ms float8, save jsonb);")
for x in json.load(open(sys.argv[3])):
    print("insert into t.honest values (%s, %r, %s::jsonb);" % (q(x['name']), x['now'], q(json.dumps(x['save']))))
PY
P -d $DB -f - < "$OUT/extra.sql" >/dev/null
P -d $DB -c "create table t.sim (n bigserial, file text, j jsonb)"
for f in "$SIM"/*.jsonl; do [[ -s "$f" ]] || continue; b=$(basename "$f" .jsonl)
  P -d $DB -c "create temp table r(line text); copy r from stdin with (format csv, quote e'\x01', delimiter e'\x02'); insert into t.sim(file, j) select '$b', line::jsonb from r where line <> ''" < "$f"; done
echo "   sims: $(PA -d $DB -c "select count(*) || ' snapshots, ' || count(distinct file) || ' runs' from t.sim")"
PA -d $DB -c "create table t.live_before as select user_id, public.kodhane_score_plausible(data) as ok from public.kodhane_saves"
PA -d $DB -c "create table t.lb_before as select g, l.* from (values ('kodhane'), ('acik_ofis')) v(g), lateral public.kodhane_leaderboard(100, g) l"
ao_state $DB > "$OUT/ao_pre.txt"
P -d $DB -F ' | ' -f - < "$PRE" > "$OUT/preflight_before.txt" 2>&1; sed 's/^/   /' "$OUT/preflight_before.txt"
P -d $DB -1 -f - < "$MIG" >/dev/null 2>&1; P -d $DB -1 -f - < "$MIG" >/dev/null 2>&1
P -d $DB -f - < "$PRE" > "$OUT/preflight_after.txt" 2>&1
grep -q 'v4.4a ALREADY APPLIED' "$OUT/preflight_after.txt" && pass "P1 preflight recognises an applied A" || fail "P1 preflight after A"
# diagnostics view of the same body (share_cap etc.) for the cheat builders
python3 - "$MIG" <<'PY' | P -d $DB -f - >/dev/null
import sys
b = open(sys.argv[1]).read().split('-- <v4_4a_body>\n')[1].split('\n-- </v4_4a_body>')[0]
i = b.index('  select case'); j = b.index('\n  from (\n    select n.*')
d = 'select (' + b[len('select coalesce(('):i] + '  select to_jsonb(v)' + b[j:]
d = d[:d.rindex('), false)')] + ')'
print("create or replace function t.diag(d jsonb, p_now timestamptz default now()) returns jsonb language sql stable set search_path to '' as $f$\n" + d + "\n$f$;")
PY
n=$(PA -d $DB -c "with a as (select g, l.* from (values ('kodhane'), ('acik_ofis')) v(g), lateral public.kodhane_leaderboard(100, g) l)
  select (select count(*) from (select * from a except all select * from t.lb_before) x) + (select count(*) from (select * from t.lb_before except all select * from a) y)"); [[ $n == 0 ]] && pass "K1 kodhane_leaderboard output (both games) identical right after A (0 rows differ)" || fail "K1 leaderboard differs in $n rows"
if [[ $HAVE_LIVE == 1 ]]; then T="$ROOT/tests/v4_4/v4_4a_plausible.test.sql"; else T="$OUT/tests_no_live.sql"; sed '/^-- ---.* L: dry-run/,$d' "$ROOT/tests/v4_4/v4_4a_plausible.test.sql" > "$T"; echo "   (no live copy: L1 skipped)"; fi
P -d $DB -v fik=$FIKUID -f - < "$T" > "$OUT/sqltests.raw" 2>&1 || echo "   SQL test file stopped: $(grep -m1 ERROR "$OUT/sqltests.raw")"
grep -oE '(NOTICE:  )(PASS|FAIL) .*' "$OUT/sqltests.raw" | sed -E 's/^NOTICE:  //' > "$OUT/sqltests.txt" || true
cat "$OUT/sqltests.txt"; NF=$(grep -c "^FAIL" "$OUT/sqltests.txt" || true); FAILS=$((FAILS + NF))
[[ $(grep -c '^PASS' "$OUT/sqltests.txt") -gt 0 ]] || fail "SQL tests did not run"
ao_state $DB > "$OUT/ao_post.txt"; same AO1_acik_ofis_data_leaderboard_functions "$OUT/ao_pre.txt" "$OUT/ao_post.txt"
P -d $DB -1 -f - < "$RB" >/dev/null 2>&1; P -d $DB -1 -f - < "$RB" >/dev/null 2>&1
P -d $DB -c "drop schema t cascade" >/dev/null 2>&1
dump $DB > "$OUT/post.sql"; fdefs $DB > "$OUT/post.fdefs"
same R6_schema_after_tests_and_rollback "$OUT/pre.sql" "$OUT/post.sql"; same R7_fdefs_after_tests_and_rollback "$OUT/pre.fdefs" "$OUT/post.fdefs"
ao_state $DB > "$OUT/ao_rb.txt"; same AO2_acik_ofis_after_rollback "$OUT/ao_pre.txt" "$OUT/ao_rb.txt"
P -d postgres -c "drop database $DB" -c "drop database $DB2"
TOTAL=$(grep -cE '^(PASS|FAIL)' "$OUT/sqltests.txt" || true)
echo "== done: runner checks $PASSN pass / $FAILS fail (fail count includes SQL fails); SQL tests: $TOTAL; artefacts in $OUT"
exit $(( FAILS > 0 ))
