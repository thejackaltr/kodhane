#!/usr/bin/env bash
# Package A before/after check (ops/v4_4a_leaderboard_snapshot.sql + ops/v4_4a_leaderboard_compare.py) on REAL reads of a
# LOCAL THROWAWAY database ($V44_CT container, template $V44_BASE = live public schema after v2.2, no data). Never point this
# at the live DB: it creates/drops databases and writes rows. Each case: fresh DB, seed, snapshot, migration A, (event), snapshot, compare.
#   V44_CT=<container> bash supabase/tests/v4_4/run_v4_4a_compare_tests.sh 2>&1 | tee /tmp/v44a-cmp.log
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CT="${V44_CT:-v44db}"; BASE="${V44_BASE:-v44_base}"; DB=v44a_cmp; OUT="${V44_OUT:-/tmp/v44a-cmp}"; mkdir -p "$OUT"; chmod 700 "$OUT"
SNAP="$ROOT/ops/v4_4a_leaderboard_snapshot.sql"; CMP="$ROOT/ops/v4_4a_leaderboard_compare.py"
MIG="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"; FIX="$ROOT/tests/fixtures/v4_4a_compensated_save.json"
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
FAILS=0; PASSN=0; pass() { echo "PASS $*"; PASSN=$((PASSN+1)); }; fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
fresh() { P -d postgres -c "drop database if exists $DB" -c "create database $DB template $BASE" >/dev/null 2>&1; }
snap() { docker exec -i "$CT" psql -U supabase_admin -X -v ON_ERROR_STOP=1 -d $DB -f - < "$SNAP" > "$OUT/$1.txt" 2>&1 || echo "   snapshot $1 failed: $(grep -m1 ERROR "$OUT/$1.txt")"; }   # no -q: BEGIN / ROLLBACK tags are checked
apply_a() { P -d $DB -1 -f - < "$MIG" > "$OUT/apply.log" 2>&1 || echo "   migration failed: $(grep -m1 ERROR "$OUT/apply.log")"; }
sql() { P -d $DB -c "$1" >/dev/null; }
U=(11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222 33333333-3333-4333-8333-333333333333
   44444444-4444-4444-8444-444444444444 55555555-5555-4555-8555-555555555555)
save() {  # save <total> <run> <shares/rounds> -> honest v4.3 save (plausible under v4.3 and v4.4a)
  echo "jsonb_build_object('version', 4, 'saveVersion', 4, 'startedAt', floor(extract(epoch from now() - interval '20 hours') * 1000),
    'lastSaved', floor(extract(epoch from now() - interval '1 minute') * 1000), 'totalEarned', $1, 'runEarned', $2, 'cycleEarned', $1,
    'shares', $3, 'prestigeCount', $3, 'cycleRounds', $3, 'ipoCount', 0, 'ipoSharesEarned', 0, 'stage', 3, 'stageBest', 3)"; }
seed() {  # 3 honest players; with "comp": + the anonymous compensated save (v4.3 false, v4.4a true)
  local s="set session_replication_role = replica;"
  for i in 0 1 2; do s+="insert into auth.users (id, aud, role) values ('${U[$i]}', 'authenticated', 'authenticated');
    insert into public.kodhane_profiles (user_id, nickname) values ('${U[$i]}', 'Oyuncu $i');"; done
  s+="insert into public.kodhane_saves (user_id, data, save_version, updated_at, best_score, revision, best_stage) values
    ('${U[0]}', $(save 5e8 2e8 2), 4, now() - interval '1 hour', 5e8, 10, 3),
    ('${U[1]}', $(save 3e8 1e8 2), 4, now() - interval '1 hour', 3e8, 10, 3),
    ('${U[2]}', $(save 2e8 1e8 1), 4, now() - interval '1 hour', 2e8, 10, 3);"
  if [[ "${1:-}" == comp ]]; then
    s+="$(python3 - "$FIX" "${U[3]}" <<'PY'
import json, sys
q = lambda s: "'" + str(s).replace("'", "''") + "'"
f = json.load(open(sys.argv[1])); u = sys.argv[2]
print("insert into auth.users (id, aud, role) values (%s, 'authenticated', 'authenticated');" % q(u))
print("insert into public.kodhane_profiles (user_id, nickname) values (%s, 'Telafi');" % q(u))
print("insert into public.kodhane_saves (user_id, data, save_version, updated_at, best_score, revision, best_stage) values (%s, %s::jsonb, 4, now() - interval '1 hour', %r, %d, %d);"
      % (q(u), q(json.dumps(f['data'])), f['best_score'], f['revision'], f['best_stage']))
PY
)"
  fi
  s+="set session_replication_role = origin;"; sql "$s"; }
expect() {  # expect <case> <exit code> [grep pattern that must appear in the compare output]
  python3 "$CMP" "$OUT/$1.before.txt" "$OUT/$1.after.txt" > "$OUT/$1.cmp" 2>&1; local rc=$?
  if [[ $rc == "$2" ]] && { [[ -z "${3:-}" ]] || grep -qE "$3" "$OUT/$1.cmp"; }; then pass "$1 (exit $rc$( [[ -n "${3:-}" ]] && echo ", '$3'"))"
  else fail "$1: exit $rc, expected $2 ${3:+/ '$3'}; $(grep -m1 -E '^(FAIL|WARN)' "$OUT/$1.cmp")"; fi; }
run() {  # run <case> <seed arg> <event SQL or ''>
  fresh; seed "$2"; snap "$1.before"; apply_a; [[ -n "$3" ]] && sql "$3"; snap "$1.after"; }

echo "== seed sanity: every seeded save plausible under v4.3; compensated save v4.3 false"
fresh; seed comp
r=$(P -d $DB -At -c "select string_agg(coalesce(public.kodhane_score_plausible(data)::text, 'null'), ',' order by user_id) from public.kodhane_saves")
[[ "$r" == "true,true,true,false" ]] && pass "S1 seed: 3 honest true, compensated false under v4.3 ($r)" || fail "S1 seed $r"

W1="update public.kodhane_saves set revision = revision + 1, updated_at = now(), best_score = 6e8,
  data = data || jsonb_build_object('totalEarned', 6e8, 'cycleEarned', 6e8, 'runEarned', 3e8, 'lastSaved', floor(extract(epoch from now()) * 1000))
  where user_id = '${U[1]}'"
run C1_pass_no_change "" "";                                                       expect C1_pass_no_change 0 'RESULT PASS'
run C2_rule_changed "comp" "";                                                     expect C2_rule_changed 1 'rule result false -> true'
run C3_player_write_in_window "" "$W1";                                            expect C3_player_write_in_window 0 'player write in the window'
grep -q 'rank-only move' "$OUT/C3_player_write_in_window.cmp" && pass "C3b overtaken row: rank-only move explained" || fail "C3b no rank-only move seen"
run C4_score_changed_outside_window "" "set session_replication_role = replica; update public.kodhane_saves set best_score = 9e8 where user_id = '${U[2]}'"
expect C4_score_changed_outside_window 1 'WITHOUT a player write'
run C5_row_vanished "" "set session_replication_role = replica; delete from public.kodhane_saves where user_id = '${U[2]}'"
expect C5_row_vanished 1 'vanished'
run C6_row_appeared "" "set session_replication_role = replica; insert into auth.users (id, aud, role) values ('${U[4]}', 'authenticated', 'authenticated');
  insert into public.kodhane_profiles (user_id, nickname) values ('${U[4]}', 'Yeni'); insert into public.kodhane_saves (user_id, data, save_version, best_score, revision, best_stage)
  values ('${U[4]}', $(save 1e8 1e8 0), 4, 1e8, 1, 3)"
expect C6_row_appeared 1 'appeared'
run C7_rule_changed_player_in_window "comp" "update public.kodhane_saves set revision = revision + 1, updated_at = now() where user_id = '${U[3]}'"
expect C7_rule_changed_player_in_window 1 'rule result false -> true \(player wrote in the window\)'
head -n 6 "$OUT/C1_pass_no_change.after.txt" > "$OUT/C8_unreadable.after.txt"; cp "$OUT/C1_pass_no_change.before.txt" "$OUT/C8_unreadable.before.txt"
expect C8_unreadable 3 'RESULT WARN'
echo "== expectation 0/0 (YY 2026-10-01 20:24; the 07:57 allow list was withdrawn): production preflight + compare"
PRE="$ROOT/ops/v4_4a_preflight.sql"; REP="$ROOT/ops/v4_4a_scores_report.sql"
fixdata() {  # fixdata '<json overrides>' -> jsonb literal of the compensated fixture save with overrides
  python3 - "$FIX" "$1" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))['data']; d.update(json.loads(sys.argv[2]))
print("'" + json.dumps(d).replace("'", "''") + "'::jsonb")
PY2
}
addsave() {  # addsave <uid> <nick> <data sql> <revision> : best_score = totalEarned, best_stage 5 (row does not move under A)
  sql "set session_replication_role = replica; insert into auth.users (id, aud, role) values ('$1', 'authenticated', 'authenticated');
    insert into public.kodhane_profiles (user_id, nickname) values ('$1', '$2');
    insert into public.kodhane_saves (user_id, data, save_version, updated_at, best_score, revision, best_stage, strict_revision)
    values ('$1', $3, 4, now() - interval '1 hour', public.kodhane_save_score($3), $4, 5, true); set session_replication_role = origin;"; }
COMP_LIKE="$(fixdata '{}')"                                                      # fa7c-like: v4.3 false, v4.4a true (rev 1107 shape)
HONEST_TRUE="$(fixdata '{"shares": 10}')"                                       # passes v4.3 and v4.4a
TRUE_THEN_FALSE="$(fixdata '{"shares": 10, "stageId": "ajans"}')"               # v4.3 true; v4.4a false (format 4 with a stage ID)
pre_expect() {  # pre_expect <case> <PASS|STOP> [pattern]   (production preflight)
  P -d $DB -f - < "$PRE" > "$OUT/$1.pre" 2>&1
  if grep -qE "EXPECTATION +\| +$2 " "$OUT/$1.pre" && { [[ -z "${3:-}" ]] || grep -qE "$3" "$OUT/$1.pre"; }; then pass "$1 preflight $2$( [[ -n "${3:-}" ]] && echo ", '$3'")"
  else fail "$1: expected preflight $2 ${3:+/ '$3'}; got: $(grep -m1 -E 'EXPECTATION|ERROR' "$OUT/$1.pre" | tr -s ' ' | cut -c1-240)"; fi; }
xrun() {  # xrun <case> <data sql for ${U[3]}> <revision> <event SQL or ''> <PASS|STOP> [pattern]: preflight on the seeded state, then snapshot / A / (event) / snapshot
  fresh; seed ""; addsave "${U[3]}" Telafi "$2" "$3"; pre_expect "$1" "$5" "${6:-}"; snap "$1.before"; apply_a; [[ -n "$4" ]] && sql "$4"; snap "$1.after"; }
# Z1: nothing changes (the live state since 16:13: every save true under both rules) -> preflight PASS and compare PASS
xrun Z1_no_change "$HONEST_TRUE" 1112 "" PASS "newly_flagged 0; newly_accepted 0 \(4 saves, no rule result changes\)"
expect Z1_no_change 0 'RESULT PASS \(no rule result changed'
# Z2: one fa7c-like save false -> true (the withdrawn case) -> preflight STOP, compare FAIL
xrun Z2_single_false_to_true "$COMP_LIKE" 1107 "" STOP "newly_accepted 1 \(must be 0\)"
expect Z2_single_false_to_true 1 "save kodhane [0-9a-f]{16}: rule result false -> true$"
# Z3: same, the player writes in the window -> still FAIL (rule result change)
xrun Z3_single_false_to_true_player_write "$COMP_LIKE" 1107 "update public.kodhane_saves set revision = revision + 1, updated_at = now() where user_id = '${U[3]}'" STOP "newly_accepted 1"
expect Z3_single_false_to_true_player_write 1 "rule result false -> true \(player wrote in the window\)"
# Z4: a newly flagged save (true -> false) -> preflight STOP, compare FAIL
xrun Z4_newly_flagged "$TRUE_THEN_FALSE" 20 "" STOP "newly_flagged 1 \(must be 0\)"
expect Z4_newly_flagged 1 "rule result true -> false$"
# Z5: player write in the window, no rule change, score moves -> PASS (explained)
xrun Z5_write_in_window_no_rule_change "$HONEST_TRUE" 1112 "update public.kodhane_saves set revision = revision + 1, updated_at = now(), best_score = best_score * 2,
  data = data || jsonb_build_object('totalEarned', (data->>'totalEarned')::numeric * 2, 'lastSaved', floor(extract(epoch from now()) * 1000)) where user_id = '${U[3]}'" PASS
expect Z5_write_in_window_no_rule_change 0 'score changed, player write in the window'
P -d $DB -f - < "$PRE" > "$OUT/Z6_after_A.pre" 2>&1   # DB of Z5 has A applied now
grep -qE 'EXPECTATION +\| +STOP .*not the v4.3 rule' "$OUT/Z6_after_A.pre" && pass "Z6 preflight after A: STOP (live rule is not v4.3)" || fail "Z6 preflight after A: $(grep -m1 EXPECTATION "$OUT/Z6_after_A.pre" | tr -s ' ')"
python3 - "$CMP" "$PRE" "$REP" <<'PY2' && pass "K1 no allow list left in compare / preflight; scores report keeps fa7c + a3a7 rows" || fail "K1 allow list remnants"
import sys
c, p, r = (open(f).read() for f in sys.argv[1:])
ok = 'ALLOW' not in c and 'APPROVED' not in c and '<v4_4a_allow>' not in p and 'allow-listed' not in p
ok &= "('fa7c574270bdf8c6', 'compensated', 1), ('a3a7039e7eb78104', 'reference', 2)" in r and 'allow-listed' not in r
sys.exit(0 if ok else 1)
PY2
docker exec -i "$CT" psql -U supabase_admin -X -v ON_ERROR_STOP=1 -d $DB -f - < "$REP" > "$OUT/R1.txt" 2>&1
# keys absent locally: the functions' real return on a missing save (rule f, vetted 0, totalEarned 0), not found = revision empty
# and n (last column, matching saves) 0: SCORE|key|role|rev|rule|vetted|best|total|rank|score|stage|status|n
r1=$(awk -F'|' '$1 == "SCORE" { ok = ($4 == "" && $5 == "f" && $6 == "0" && $7 == "" && $8 == "0" && $9 $10 $11 $12 == "" && $13 == "0"); n++; if (ok) g++; if (ok && $2 == "fa7c574270bdf8c6" && $3 == "compensated") a++; if (ok && $2 == "a3a7039e7eb78104" && $3 == "reference") r++ }
  END { print (n == 2 && g == 2 && a == 1 && r == 1) ? "ok" : "bad" }' "$OUT/R1.txt")
[[ $r1 == ok ]] && grep -qx ' on' "$OUT/R1.txt" && grep -q '^ROLLBACK' "$OUT/R1.txt" && pass "R1 scores report runs read only; absent saves reported as not found (rev empty, rule f, vetted 0, n 0)" || fail "R1 scores report: $(grep -E 'ERROR|SCORE' "$OUT/R1.txt" | tr '\n' ' ')"
grep -q 'nickname\|Oyuncu\|Telafi\|Diger' "$OUT"/*.cmp "$OUT"/*.pre && fail "N1 compare output contains a nickname" || pass "N1 no nickname in any compare output"
grep -q 'Oyuncu\|Telafi' "$OUT"/C1_pass_no_change.before.txt && fail "N2 snapshot contains a nickname" || pass "N2 no nickname in the snapshot"
P -d postgres -c "drop database if exists $DB" >/dev/null
echo "== done: $PASSN pass / $FAILS fail; artefacts in $OUT"
exit $(( FAILS > 0 ))
