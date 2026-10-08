#!/usr/bin/env bash
# Package B (stage IDs + save-version guard) tests. LOCAL THROWAWAY DATABASES ONLY, same container/base as
# run_v4_4a_tests.sh ($V44_CT / $V44_BASE = live public schema after v2.2, no data). Never point this at the live DB.
#   bash supabase/tests/v4_4/run_v4_4b_tests.sh 2>&1 | tee /tmp/v44b-test.log
# Optional: $V44_LIVE_COPY (pseudonymized read-only copy of the live saves) for the leaderboard comparisons;
# V44_HTTP=1 (default) also starts a throwaway PostgREST container ($V44_PGRST_IMAGE) on the test DB for the HTTP 426 check.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CT="${V44_CT:-v44db}"; BASE="${V44_BASE:-v44_base}"; DB=v44b_test; DB2=v44b_roundtrip; DB3=v44b_guard
MIGA="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"; RBA="$ROOT/rollback/20260929203000_v4_4a_kodhane_score_plausible.rollback.sql"
MIGB="$ROOT/migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql"; RBB="$ROOT/rollback/20260929204000_v4_4b_kodhane_stage_ids_version_guard.rollback.sql"
PRE="$ROOT/ops/v4_4b_preflight.sql"; VER="$ROOT/ops/v4_4b_verify.sql"
LIVE="${V44_LIVE_COPY:-/workspace/tmp/v44/a/live_copy.sql}"
OUT="${V44_OUT:-/tmp/v44b-test}"; mkdir -p "$OUT"; chmod 700 "$OUT"
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
PA() { P -At "$@"; }
dump() { docker exec "$CT" pg_dump -U supabase_admin --schema-only -n public "$1" | grep -v '^\\\(un\)\?restrict '; }
fdefs() { PA -d "$1" -c "select p.oid::regprocedure, md5(pg_get_functiondef(p.oid)), p.proacl, coalesce(obj_description(p.oid,'pg_proc'),'')
  from pg_proc p where p.pronamespace = 'public'::regnamespace order by 1"; }
lb() { PA -d "$1" -c "select g, l::text from (values ('kodhane'), ('acik_ofis')) v(g), lateral public.kodhane_leaderboard(100, g) l order by 1, 2"; }
ao_state() { PA -d "$1" -c "select 'data', md5(string_agg(t::text, '|' order by t::text)) from (select * from public.acik_ofis_saves) t
  union all select 'lb', md5(coalesce(string_agg(l::text, '|'), '')) from public.kodhane_leaderboard(100, 'acik_ofis') l
  union all select 'funcs', md5(string_agg(pg_get_functiondef(oid) || coalesce(proacl::text,''), '|' order by oid::regprocedure::text))
    from pg_proc where pronamespace = 'public'::regnamespace and proname like 'acik_ofis%'"; }
fresh() { P -d postgres -c "drop database if exists $1" -c "create database $1 template $BASE" >/dev/null 2>&1; }
FAILS=0; PASSN=0; pass() { echo "PASS $*"; PASSN=$((PASSN+1)); }; fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
same() { if diff -u "$2" "$3" > "$OUT/$1.diff"; then pass "$1 (diff empty)"; else fail "$1: $(wc -l < "$OUT/$1.diff") diff lines, see $OUT/$1.diff"; fi; }
apply() { P -d "$1" -1 -f - < "$2" > "$OUT/apply.log" 2>&1 || { cat "$OUT/apply.log"; return 1; }; }

echo "== 1. B on top of A: apply x2, verify, rollback B x2 -> schema = A state; then rollback A -> schema = base"
fresh $DB2; dump $DB2 > "$OUT/base.sql"; fdefs $DB2 > "$OUT/base.fdefs"
apply $DB2 "$MIGA"; dump $DB2 > "$OUT/a.sql"; fdefs $DB2 > "$OUT/a.fdefs"
apply $DB2 "$MIGB"; apply $DB2 "$MIGB"; dump $DB2 > "$OUT/ab.sql"
P -d $DB2 -At -F '|' -f - < "$VER" > "$OUT/verify.txt"
if grep -q '|f$' "$OUT/verify.txt"; then fail "R1 verify: $(grep '|f$' "$OUT/verify.txt" | tr '\n' ' ')"; else pass "R1 ops/v4_4b_verify.sql all t ($(grep -c '|t$' "$OUT/verify.txt") checks)"; fi
P -d $DB2 -f - < "$PRE" > "$OUT/preflight_after_b.txt" 2>&1; grep -q 'package B: ALREADY APPLIED' "$OUT/preflight_after_b.txt" && pass "R2 preflight recognises an applied B" || fail "R2 preflight"
apply $DB2 "$RBB"; apply $DB2 "$RBB"; dump $DB2 > "$OUT/a_after_rbb.sql"; fdefs $DB2 > "$OUT/a_after_rbb.fdefs"
same R3_schema_after_rollback_B_equals_A "$OUT/a.sql" "$OUT/a_after_rbb.sql"
same R4_fdefs_after_rollback_B_equals_A "$OUT/a.fdefs" "$OUT/a_after_rbb.fdefs"
apply $DB2 "$MIGB"; dump $DB2 > "$OUT/ab2.sql"; same R5_reapply_B "$OUT/ab.sql" "$OUT/ab2.sql"
apply $DB2 "$RBB"; apply $DB2 "$RBA"; dump $DB2 > "$OUT/base_after.sql"; fdefs $DB2 > "$OUT/base_after.fdefs"
same R6_schema_after_rollback_B_then_A_equals_base "$OUT/base.sql" "$OUT/base_after.sql"
same R7_fdefs_after_rollback_B_then_A_equals_base "$OUT/base.fdefs" "$OUT/base_after.fdefs"

echo "== 2. guards"
fresh $DB3
if P -d $DB3 -1 -f - < "$MIGB" > "$OUT/g1.txt" 2>&1; then fail "G1 B applied without A"; else grep -q 'package A .* is not applied' "$OUT/g1.txt" && pass "G1 B refuses without package A" || fail "G1 wrong error: $(grep ERROR "$OUT/g1.txt")"; fi
P -d postgres -c "drop database $DB3" >/dev/null

echo "== 3. test DB: live copy + A, then B"
fresh $DB
P -d $DB -f - < "$ROOT/tests/fixtures/helpers.sql" >/dev/null
# t.plaus_a: the v4.4a body verbatim from the A migration (O3: v4.4b = v4.4a inside the float8 bounds)
python3 - "$MIGA" <<'PY' | P -d $DB -f - >/dev/null
import sys
b = open(sys.argv[1]).read().split('-- <v4_4a_body>\n')[1].split('\n-- </v4_4a_body>')[0]
print("create or replace function t.plaus_a(d jsonb, p_now timestamptz default now()) returns boolean language sql stable set search_path to '' as $f$\n" + b + "\n$f$;")
print("grant execute on function t.plaus_a(jsonb, timestamptz) to public;")
PY
HAVE_LIVE=0; if [[ -r "$LIVE" ]]; then P -d $DB -f - < "$LIVE" >/dev/null; HAVE_LIVE=1; else echo "   (no live copy: leaderboard comparisons on test rows only)"; fi
apply $DB "$MIGA"
lb $DB > "$OUT/lb_pre.txt"; ao_state $DB > "$OUT/ao_pre.txt"; PA -d $DB -c "select user_id, md5(data::text), revision, best_score, best_stage from public.kodhane_saves order by 1" > "$OUT/saves_pre.txt"
P -d $DB -f - < "$PRE" > "$OUT/preflight.txt" 2>&1; sed 's/^/   /' "$OUT/preflight.txt"
apply $DB "$MIGB"
lb $DB > "$OUT/lb_post.txt"; same K1_leaderboard_v6_both_games_identical_after_B "$OUT/lb_pre.txt" "$OUT/lb_post.txt"
PA -d $DB -c "select user_id, md5(data::text), revision, best_score, best_stage from public.kodhane_saves order by 1" > "$OUT/saves_post.txt"
same K2_no_data_write_by_B "$OUT/saves_pre.txt" "$OUT/saves_post.txt"
[[ $HAVE_LIVE == 1 ]] && { r=$(PA -d $DB -c "select count(*) || ' rows, ' || count(*) filter (where stage_id is distinct from public.kodhane_stage_legacy_id(stage)) || ' differ' from public.kodhane_leaderboard_v7(100)");
  [[ "$r" == *", 0 differ" ]] && pass "K3 live copy: v7 stage_id = legacy mapping of v6 stage for every old record ($r)" || fail "K3 $r"; }
P -d $DB -f - < "$HERE/v4_4b.test.sql" > "$OUT/sqltests.raw" 2>&1 || echo "   SQL test file stopped: $(grep -m1 ERROR "$OUT/sqltests.raw")"
grep -oE '(NOTICE:  )(PASS|FAIL) .*' "$OUT/sqltests.raw" | sed -E 's/^NOTICE:  //' > "$OUT/sqltests.txt" || true
cat "$OUT/sqltests.txt"; NF=$(grep -c "^FAIL" "$OUT/sqltests.txt" || true); FAILS=$((FAILS + NF))
[[ $(grep -c '^PASS' "$OUT/sqltests.txt" || true) -gt 0 ]] || fail "SQL tests did not run"
ao_state $DB > "$OUT/ao_post.txt"; same AO1_acik_ofis_data_leaderboard_functions_after_B_and_tests "$OUT/ao_pre.txt" "$OUT/ao_post.txt"

if [[ "${V44_HTTP:-1}" == 1 ]]; then
  echo "== 4. HTTP: PostgREST on the test DB (local container, throwaway JWT secret)"
  bash "$HERE/http_v4_4b.sh" "$CT" "$DB" > "$OUT/http.txt" 2>&1 || true
  cat "$OUT/http.txt"; NF=$(grep -c "^FAIL" "$OUT/http.txt" || true); FAILS=$((FAILS + NF)); HP=$(grep -c "^PASS" "$OUT/http.txt" || true)
  HSKIP=$(grep -m1 '^SKIP' "$OUT/http.txt" || true)
  if [[ -n "$HSKIP" && $HP -eq 0 && $NF -eq 0 ]]; then echo "   HTTP layer SKIPPED (not a pass): $HSKIP"
  else [[ $HP -gt 0 ]] || fail "HTTP tests did not run"; fi
fi
apply $DB "$RBB"; ao_state $DB > "$OUT/ao_rb.txt"; same AO2_acik_ofis_after_rollback_B "$OUT/ao_pre.txt" "$OUT/ao_rb.txt"
P -d postgres -c "drop database $DB" -c "drop database $DB2" >/dev/null
TOTAL=$(grep -cE '^(PASS|FAIL)' "$OUT/sqltests.txt" || true); HT=$(grep -cE '^(PASS|FAIL)' "$OUT/http.txt" 2>/dev/null || true)
echo "== done: runner checks $PASSN pass; SQL tests $TOTAL; HTTP checks ${HT:-0}${HSKIP:+ (HTTP SKIPPED: image not local)}; failures total $FAILS; artefacts in $OUT"
exit $(( FAILS > 0 ))
