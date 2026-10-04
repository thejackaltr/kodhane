#!/usr/bin/env bash
# Kodhane v4.5 score rule (migration 20261003080000) tests. LOCAL THROWAWAY DATABASES ONLY, in the local docker container
# $SR_CT (supabase/postgres image) whose database $SR_BASE holds the live schema (v2.2 + A, no data). Never point this
# at the live DB: it drops / creates databases.
#   SR_CT=<container> bash supabase/tests/score_rule/run_kodhane_score_rule_tests.sh 2>&1 | tee /tmp/kd-sr-test.log
# Groups: M migration (prerequisite, idempotent, B objects untouched), E equivalence / generosity (v4.4b copy vs v4.5
# on the simulation sample sim_sample.jsonl + the pseudonymized live copy), C config (one active row, fallback, bad
# curves, F3 row), P privileges (anon / authenticated / service_role, leaderboard as a player), I install package
# (kodhane_score_rule_install.sh), S stage catalogue asama_1e21 (backfill, log, leaderboard, player write; fixture
# stage_1e21_fixture.sql), R rollback (back to v4.4b byte for byte, rows recorded first and restored row by row, re-install).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; OPS="$ROOT/ops"
CT="${SR_CT:-v44x-136}"; BASE="${SR_BASE:-v44_base}"; OUT="${SR_OUT:-/tmp/kd-sr-test}"; LIVE="${SR_LIVE_COPY:-/workspace/tmp/v44/a/live_copy.sql}"
rm -rf "$OUT"; mkdir -p "$OUT"; chmod 700 "$OUT"
MIGA="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"; MIGB="$ROOT/migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql"
MIGS="$ROOT/migrations/20261003080000_v4_5_kodhane_score_rule.sql"; RBS="$ROOT/rollback/20261003080000_v4_5_kodhane_score_rule.rollback.sql"
SRV="$OPS/kodhane_score_rule/verify.sql"; INS="$OPS/kodhane_score_rule_install.sh"
B_MD5=463f2109c35b825827e57b8098b49947; V45_MD5=a52586896ae53ac8e5159aa500c4b031
# stage catalogue md5s (pg_get_functiondef of kodhane_stage_rank / kodhane_stage_at, pg_get_constraintdef of the CHECK): after B / with v4.5
B_CAT=e97a3589f1f23fe36991b986480bd509:b0aa4d9eb67eb4bb284d54c6641be791:f1e8655e57baf17f8c2330d6f252eacf
V45_CAT=e1c7af8061bc48883d2ea911213f990a:f875dd829a4e2a62a9d4b3457aa018a5:2325f40530fa6b360ca0583641750b6b
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
q() { local d=$1; shift; P -At -F '|' -d "$d" "$@" 2>>"$OUT/stderr" | sed '/^$/d'; }
qe() { local d=$1; shift; P -At -F '|' -d "$d" "$@" 2>&1 | sed '/^$/d'; }   # like q, notices / errors on stdout
FAILS=0; PASSN=0; declare -A NT=()
pass() { echo "PASS $*"; PASSN=$((PASSN+1)); local k=${1%%[0-9]*}; NT[$k]=$(( ${NT[$k]:-0} + 1 )); }
fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1  -- ${2:0:200}"; else fail "$1: got [$2] expected [$3]"; fi; }
fmd5() { q "$1" -c "select md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure))"; }
pcfg() { q "$1" -c "select coalesce(array_to_string(proconfig, ','), '-') from pg_proc where oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure"; }
cmd5() { q "$1" -c "select md5(pg_get_functiondef('public.kodhane_stage_rank(text)'::regprocedure)) || ':' || md5(pg_get_functiondef('public.kodhane_stage_at(text)'::regprocedure)) || ':' || (select md5(pg_get_constraintdef(oid)) from pg_constraint where conrelid = 'public.kodhane_saves'::regclass and conname = 'kodhane_saves_best_stage_id_known')"; }
mkdb() {  # mkdb <db> [no-b]: base + A (+ B) + live copy
  P -d postgres -c "drop database if exists $1 with (force)" -c "create database $1 template $BASE" >/dev/null 2>&1 || return 1
  P -d $1 -1 -f - < "$MIGA" >/dev/null 2>&1 || return 1
  [[ ${2:-} == no-b ]] && return 0
  P -d $1 -1 -f - < "$MIGB" >/dev/null 2>&1 || return 1
  [[ -r "$LIVE" ]] && { P -d $1 -f - < "$LIVE" >/dev/null 2>&1 || return 1; }
  return 0
}
# a copy of the v4.4b function under another name (the reference for E)
v44copy() { awk '/create or replace function public.kodhane_score_plausible/{p=1} p{print} /^\$function\$;/{if(p){exit}}' "$MIGB" \
  | sed 's/create or replace function public.kodhane_score_plausible(/create or replace function public.kodhane_score_plausible_v44b_ref(/' | P -d "$1" -f - >/dev/null; }
load_sample() { P -d "$1" -c "create table public.sr_sample (l jsonb)" >/dev/null
  python3 -c 'import sys; [print(l.strip().replace(chr(92), chr(92)*2)) for l in open(sys.argv[1]) if l.strip()]' "$HERE/sim_sample.jsonl" \
    | P -d "$1" -c "copy public.sr_sample (l) from stdin with (format text)" >/dev/null; }
echo "== container $CT: $(docker inspect -f '{{.Config.Image}} {{.Image}}' "$CT" | cut -c1-90)"

# ------------------------------------------------------------------ M migration
mkdb sr_nob no-b || { echo "setup failed"; exit 1; }
P -d sr_nob -f - < "$MIGS" > "$OUT/m0.log" 2>&1
check "M0 without package B: refused, nothing created" "$(grep -c 'package B (20260929204000' "$OUT/m0.log")|$(q sr_nob -c "select to_regnamespace('kodhane_rule') is null")" "1|t"
P -d postgres -c "drop database sr_nob with (force)" >/dev/null 2>&1
D=sr_main; mkdb $D || { echo "setup $D failed"; exit 1; }
check "M1 after B: kodhane_score_plausible is v4.4b ($B_MD5)" "$(fmd5 $D)" "$B_MD5"
others() { q $D -c "select md5(string_agg(p.oid::regprocedure::text || ':' || md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname not in ('kodhane_score_plausible', 'kodhane_stage_rank', 'kodhane_stage_at') and p.prokind = 'f'"; }
trg() { q $D -c "select string_agg(tgname || ':' || tgenabled::text, ',' order by tgname) from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and not tgisinternal"; }
acl() { q $D -c "select proacl::text || '|' || pg_get_userbyid(proowner) from pg_proc where oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure"; }
F0=$(others); T0=$(trg); A0=$(acl); C0=$(cmd5 $D)
P -d $D -f - < "$MIGS" > "$OUT/m2.log" 2>&1 && pass "M2 migration applies (own transaction)" || fail "M2 $(grep -m1 ERROR "$OUT/m2.log")"
check "M3 definition md5 = reviewed v4.5 ($V45_MD5); comment v4.5" "$(fmd5 $D)|$(q $D -c "select obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc') like 'Kodhane leaderboard heuristic v4.5 %'")" "$V45_MD5|t"
check "M3b SET jit = off: proconfig search_path + jit=off (after B: search_path only)" "$(pcfg $D)" 'search_path="",jit=off'
check "M4 B / A untouched: other public functions, kodhane_saves triggers (+ the two stage log triggers), plausible owner + ACL" "$(others)|$(trg)|$(acl)" \
  "$F0|$T0,kodhane_saves_zz_stage_1e21_log_ins:O,kodhane_saves_zz_stage_1e21_log_upd:O|$A0"
check "M4b stage catalogue: after B $B_CAT; with v4.5 $V45_CAT (rank / at / CHECK); asama_1e21 rank 10 at 1e21, mars_ofisi 11" \
  "$C0|$(cmd5 $D)|$(q $D -c "select public.kodhane_stage_rank('asama_1e21') || ':' || public.kodhane_stage_at('asama_1e21') || ':' || public.kodhane_stage_rank('mars_ofisi')")" "$B_CAT|$V45_CAT|10:1000000000000000000000:11"
docker exec "$CT" pg_dump -U supabase_admin --schema-only -d $D | grep -v '^\\\(un\)\?restrict ' > "$OUT/s1.sql"
P -d $D -f - < "$MIGS" > "$OUT/m5.log" 2>&1; docker exec "$CT" pg_dump -U supabase_admin --schema-only -d $D | grep -v '^\\\(un\)\?restrict ' > "$OUT/s2.sql"
check "M5 idempotent: second run OK, schema identical, still 2 curve rows" "$(diff -q "$OUT/s1.sql" "$OUT/s2.sql" >/dev/null && echo same)|$(q $D -c "select count(*) || ':' || string_agg(id || '=' || active, ',' order by id) from kodhane_rule.score_curve")" "same|2:v45_f2=true,v45_f3=false"
check "M6 install verify (read only)" "$(q $D -f - < "$SRV" | grep -E '^SRVERIFY')" "SRVERIFY|PASS|14"

( env KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$D KODHANE_OUT=$OUT/bbuild bash "$OPS/kodhane_v44b_install.sh" build > "$OUT/bbuild.out" 2>&1 )
check "M7 package B build PASS, install.sql unchanged (deefef0e...) and without the score rule" \
  "$(grep -c '^BUILD|PASS' "$OUT/bbuild.out")|$(md5sum < "$OUT/bbuild/sql/install.sql" | cut -c1-32)|$(grep -c 'kodhane_rule' "$OUT/bbuild/sql/install.sql")" "1|deefef0e5c52cc3679dc997374d2edbb|0"

# ------------------------------------------------------------------ E equivalence / generosity
v44copy $D; load_sample $D
q $D -c "insert into kodhane_rule.score_curve (id, growth, tier_mult, ik_factor, borsa_cut, note) values ('v44b_equiv', '[[0, 1.15]]', 32, 0.14::float8 / 0.15, 1, 'test only')" >/dev/null
J="from public.sr_sample s cross join lateral (select s.l -> 'd' as d, to_timestamp((s.l ->> 'now')::float8 / 1000) as at) x"
check "E0 sample: rows / sim rejections (v4.4a mirror) / rejections with asama_1e21 known" "$(q $D -c "select count(*) || '|' || count(*) filter (where not (s.l ->> 'sim_ok')::boolean) || '|' || count(*) filter (where not (s.l ->> 'sim_ok_1e21')::boolean) from public.sr_sample s")" "677|137|7"
check "E1 v4.4b SQL = the simulation's rule mirror on every sample row (0 mismatches)" "$(q $D -c "select count(*) filter (where public.kodhane_score_plausible_v44b_ref(x.d, x.at) <> (s.l ->> 'sim_ok')::boolean) $J")" "0"
eqset() { q $D -c "update kodhane_rule.score_curve set active = false" -c "update kodhane_rule.score_curve set active = true where id = '$1'" >/dev/null; }
eqset v44b_equiv
check "E2 curve [[0, 1.15]], tier 32, cut 1 (= v4.4b formula): v4.5 = v4.4b with asama_1e21 known on every sample row" \
  "$(q $D -c "select count(*) filter (where public.kodhane_score_plausible(x.d, x.at) <> (s.l ->> 'sim_ok_1e21')::boolean) $J")" "0"
check "E2b same equivalence on the live copy saves and on edge vectors (v4.3 / v4.4 formats, huge, negative, wrong types)" \
  "$(q $D -c "with v(d) as (select data from public.kodhane_saves union all values ('{\"totalEarned\": 0}'::jsonb), ('{\"totalEarned\": 1e299}'), ('{\"totalEarned\": -1}'), ('{\"totalEarned\": \"5\"}'), ('[1]'), ('{\"totalEarned\": 1e12, \"ipoCount\": 2, \"prestigeCount\": 9, \"cycleRounds\": 2, \"shares\": 40, \"ipoSharesEarned\": 3, \"saveVersion\": 5}'), ('{\"totalEarned\": 5e8, \"shares\": 1e60}')) select count(*) || '|' || count(*) filter (where public.kodhane_score_plausible(d) is distinct from public.kodhane_score_plausible_v44b_ref(d)) from v")" \
  "$(( $(q $D -c "select count(*) from public.kodhane_saves") + 7 ))|0"
eqset v45_f2
check "E3 v45_f2: no sample row that v4.4b accepts is refused (more generous everywhere)" "$(q $D -c "select count(*) filter (where public.kodhane_score_plausible_v44b_ref(x.d, x.at) and not public.kodhane_score_plausible(x.d, x.at)) $J")" "0"
check "E4 v45_f2: sample rejections v4.4b -> v4.5 (only Karar 1 'A prev' remain)" "$(q $D -c "select count(*) filter (where not public.kodhane_score_plausible_v44b_ref(x.d, x.at)) || '>' || count(*) filter (where not public.kodhane_score_plausible(x.d, x.at)) || '|' || coalesce(string_agg(distinct s.l ->> 'job', ',') filter (where not public.kodhane_score_plausible(x.d, x.at) and s.l ->> 'job' not like 'F-K1-%'), '-') $J")" "137>7|-"
check "E5 live copy: every save plausible under v4.4b stays plausible" "$(q $D -c "select count(*) filter (where public.kodhane_score_plausible_v44b_ref(data) and not public.kodhane_score_plausible(data)) from public.kodhane_saves")" "0"
eqset v45_f3
check "E3b v45_f3 (H20, costlier at 100-300): still no sample / live copy save that v4.4b accepts is refused (units never below v4.4b)" \
  "$(q $D -c "select count(*) filter (where public.kodhane_score_plausible_v44b_ref(x.d, x.at) and not public.kodhane_score_plausible(x.d, x.at)) $J")|$(q $D -c "select count(*) filter (where public.kodhane_score_plausible_v44b_ref(data) and not public.kodhane_score_plausible(data)) from public.kodhane_saves")" "0|0"
# E8: B bound at its edge, against an independent unit-by-unit reference (boundary_vectors.py): e = e* x 1.001 -> true, e* / 1.001 -> false
q $D -c "create table public.sr_vec (label text, d jsonb, now_ms float8, expected boolean)" >/dev/null
for c in f2 f3 v44; do python3 "$HERE/boundary_vectors.py" $c | P -d $D -c "copy public.sr_vec from stdin with (format text)" >/dev/null; done
VJ="from public.sr_vec v cross join lateral (select to_timestamp(v.now_ms / 1000) as at) x"
for c in f2 f3 v44; do
  id=v45_$c; [[ $c == v44 ]] && id=v44b_equiv; eqset $id
  r=$(q $D -c "select count(*) || '|' || count(*) filter (where public.kodhane_score_plausible(v.d, x.at) <> v.expected) || '|' || coalesce(string_agg(v.label, ',') filter (where public.kodhane_score_plausible(v.d, x.at) <> v.expected), '-') $VJ where v.label like '$c|%'")
  [[ $c == v44 ]] && r="$r|ref $(q $D -c "select count(*) filter (where public.kodhane_score_plausible_v44b_ref(v.d, x.at) <> v.expected) $VJ where v.label like 'v44|%'")"
  exp="$(python3 "$HERE/boundary_vectors.py" $c | wc -l)|0|-"; [[ $c == v44 ]] && exp="$exp|ref 0"
  check "E8$c B bound at the edge (x1.001 in / out) = independent unit-by-unit reference, curve $id, pre / post Halka Arz, t grid 1e9 ... 1e60 (edge inside the time window)" "$r" "$exp"
done
eqset v45_f2
# stage asama_1e21: known, but only reachable with totalEarned >= 1e21
S21="jsonb_build_object('saveVersion', 5, 'version', 5, 'totalEarned', %s, 'runEarned', 0, 'cycleEarned', %s, 'shares', 5441797, 'prestigeCount', 22, 'cycleRounds', 19, 'ipoCount', 1, 'ipoSharesEarned', 1, 'stageId', 'freelancer', 'stageBestId', '%s', 'cycleStageId', '%s', 'startedAt', floor(extract(epoch from now() - interval '12 hours') * 1000), 'lastSaved', floor(extract(epoch from now()) * 1000))"
v() { q $D -c "select public.kodhane_score_plausible($(printf "$S21" "$1" "$1" "$2" "$2"))::text || '/' || public.kodhane_score_plausible_v44b_ref($(printf "$S21" "$1" "$1" "$2" "$2"))::text"; }
check "E6 asama_1e21 at 1.15e21: v4.5 t / v4.4b f; at 9e20 (below 1e21) both f; yapay_zeka_lab at 1.15e21 both t" "$(v 1.149894005101156e21 asama_1e21) $(v 9e20 asama_1e21) $(v 1.149894005101156e21 yapay_zeka_lab)" "true/false false/false true/true"
check "E7 still refuses: 1e40 after 2 h, unknown employee, unknown stage id, format-4 save with a stage id" \
  "$(q $D -c "select public.kodhane_score_plausible(jsonb_build_object('saveVersion', 5, 'totalEarned', 1e40, 'runEarned', 1e40, 'cycleEarned', 1e40, 'startedAt', floor(extract(epoch from now() - interval '2 hours') * 1000)))::text || public.kodhane_score_plausible('{\"saveVersion\": 5, \"totalEarned\": 100, \"gens\": {\"robot\": 1}}')::text || public.kodhane_score_plausible('{\"saveVersion\": 5, \"totalEarned\": 100, \"stageId\": \"asama_x\"}')::text || public.kodhane_score_plausible('{\"version\": 4, \"totalEarned\": 1e22, \"stageId\": \"asama_1e21\"}')::text")" "falsefalsefalsefalse"

# ------------------------------------------------------------------ C config
check "C1 a second active row -> 23505 (score_curve_one_active)" "$(q $D -c "do \$\$ begin update kodhane_rule.score_curve set active = true where id = 'v45_f3'; exception when unique_violation then raise notice 'U'; end \$\$" 2>&1; grep -c 'NOTICE:  U' "$OUT/stderr")" "1"
r=""; for g in '[[1, 1.15]]' '[[0, 1.15], [300, 1.1], [200, 1.05]]' '[[0, 1]]' '[[0, 3]]' '[[0, 1.15], [10.5, 1.1]]' '{}' '[]' '[[0, "1.15"]]'; do
  r="$r $(qe $D -c "do \$\$ begin insert into kodhane_rule.score_curve (id, growth, tier_mult, ik_factor, borsa_cut) values ('bad', '$g', 727, 0.9, 0.8); raise notice 'INSERTED'; exception when check_violation then raise notice 'CHK'; end \$\$" 2>&1 | grep -oE 'CHK|INSERTED')"; done
check "C2 bad curves refused by the CHECK (start not 0, not increasing, growth 1 / 3, non-integer start, not an array, empty, string)" "$r" "$(printf ' CHK%.0s' {1..8})"
r=""; for c in "tier_mult = 31" "tier_mult = 2e6" "ik_factor = 0" "ik_factor = 1.5" "borsa_cut = 0" "borsa_cut = 1.1" "id = 'Bad-Id'"; do
  r="$r $(qe $D -c "do \$\$ begin update kodhane_rule.score_curve set $c where id = 'v45_f3'; raise notice 'UPDATED'; exception when check_violation then raise notice 'CHK'; end \$\$" 2>&1 | grep -oE 'CHK|UPDATED')"; done
check "C3 out-of-range tier_mult / ik_factor / borsa_cut / id refused" "$r" "$(printf ' CHK%.0s' {1..7})"
R0=$(q $D -c "select md5(string_agg(public.kodhane_score_plausible(x.d, x.at)::text, ',' order by s.l ->> 'job', (s.l ->> 'i')::int)) $J")
q $D -c "update kodhane_rule.score_curve set active = false" >/dev/null
check "C4 no active row: the helper falls back to the built-in v45_f2 values (same judgement on every sample row; nobody hidden)" \
  "$(q $D -c "select md5(string_agg(public.kodhane_score_plausible(x.d, x.at)::text, ',' order by s.l ->> 'job', (s.l ->> 'i')::int)) $J")|$(q $D -c "select count(*) from kodhane_rule.active_score_curve()")" "$R0|1"
eqset v45_f3
check "C5 v45_f3 (H20) active: helper returns it; sample rejections (F3 curve is costlier 100-300 but tiers x727)" "$(q $D -c "select growth::text from kodhane_rule.active_score_curve()")|$(q $D -c "select count(*) filter (where not public.kodhane_score_plausible(x.d, x.at)) $J")" "[[0, 1.15], [100, 1.20], [300, 1.10], [500, 1.05], [1000, 1.025], [3000, 1.0125]]|7"
eqset v45_f2; q $D -c "delete from kodhane_rule.score_curve where id = 'v44b_equiv'" >/dev/null
check "C6 back to v45_f2: verify PASS" "$(q $D -f - < "$SRV" | grep -E '^SRVERIFY')" "SRVERIFY|PASS|14"

# ------------------------------------------------------------------ P privileges
asr() { qe $D -c "set role $1" -c "$2" | grep -vE '^(LINE [0-9]+:|HINT:|DETAIL:| +\^)' | grep -v '^ *$' | tail -n1; }   # last result / ERROR line
check "P1 anon / authenticated: no SELECT on score_curve, no EXECUTE on the helper (42501)" \
  "$(asr anon "select count(*) from kodhane_rule.score_curve" | grep -c 'permission denied')$(asr authenticated "select * from kodhane_rule.active_score_curve()" | grep -c 'permission denied')$(asr authenticated "select public.kodhane_score_plausible('{\"totalEarned\": 0}')" | grep -c 'permission denied')" "111"
check "P2 service_role: kodhane_score_plausible works (helper reachable), table still closed" \
  "$(asr service_role "select public.kodhane_score_plausible('{\"totalEarned\": 0}')")|$(asr service_role "select count(*) from kodhane_rule.score_curve" | grep -c 'permission denied')" "t|1"
U=$(q $D -c "select user_id from public.kodhane_profiles limit 1")
check "P3 leaderboard v7 as a player (authenticated, JWT sub) works and lists the live copy players" \
  "$(q $D -c "select set_config('role', 'authenticated', false), set_config('request.jwt.claim.sub', '$U', false)" -c "select count(*) > 0 from public.kodhane_leaderboard_v7(100)" | tail -n1)" "t"

# ------------------------------------------------------------------ I install package
DI=sr_ins; mkdb $DI || { echo "setup $DI failed"; exit 1; }
P -d $DI -f - < "$HERE/stage_1e21_fixture.sql" > "$OUT/fixture.log" 2>&1 || { echo "fixture failed: $(grep -m1 ERROR "$OUT/fixture.log")"; exit 1; }
SU="5e210000-0000-4000-8000-00000000000"
srows() { q $DI -c "select string_agg(right(user_id::text, 1) || '=' || coalesce(best_stage_id, 'NULL'), ' ' order by right(user_id::text, 1)) from public.kodhane_saves where user_id::text like '$SU%'"; }
ssnap() { q $DI -c "select md5(string_agg(user_id::text || ':' || revision || ':' || strict_revision || ':' || best_score || ':' || best_stage || ':' || md5(data::text) || ':' || updated_at, ',' order by user_id)) from public.kodhane_saves"; }
slb() { q $DI -c "select string_agg(right(nickname, 1) || '=' || coalesce(stage_id, '-'), ' ' order by nickname) from public.kodhane_leaderboard_v7(1000) where nickname like 'SR Aşama %'"; }
check "S0 fixture under B: best_stage_id a=yapay_zeka_lab b=NULL c=teknoloji_devi (all three now at asama_1e21), d e f; leaderboard shows A with yapay_zeka_lab (the wrong stage name)" \
  "$(srows)|$(slb)" "a=yapay_zeka_lab b=NULL c=teknoloji_devi d=yapay_zeka_lab e=mars_ofisi f=NULL|A=yapay_zeka_lab C=teknoloji_devi D=yapay_zeka_lab"
ins() { local o=$1 st=$2; shift 2; env KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$DI KODHANE_OUT="$OUT/$o" "$@" bash "$INS" $st 2>&1; }
r=""; for st in build preflight dryrun; do r="$r $(ins i1 $st | grep -E '^(BUILD|PREFLIGHT|DRYRUN)\|PASS' | tail -n1)"; done
check "I1 build / preflight / dryrun PASS; dry run leaves v4.4b ($B_MD5), no kodhane_rule" "$r|$(fmd5 $DI)|$(q $DI -c "select to_regnamespace('kodhane_rule') is null")" " BUILD|PASS PREFLIGHT|PASS DRYRUN|PASS|$B_MD5|t"
check "I2 preflight dry run on the live copy: all plausible now stay plausible (became_false 0)" "$(grep -oE 'became_false\|[0-9]+' "$OUT/i1/preflight.out")" "became_false|0"
check "S1 preflight prints 3 backfill candidates; dryrun prints rows 3 (NULL:1, teknoloji_devi:1, yapay_zeka_lab:1) + 3 BFROW lines; after the dry run nothing written" \
  "$(grep -oE '^INFO\|stage_1e21_backfill_candidates\|[0-9]+' "$OUT/i1/preflight.out")|$(grep -E '^INFO\|stage_1e21_backfill\|' "$OUT/i1/dryrun.out")|$(grep -c '^BFROW|' "$OUT/i1/dryrun.out")|$(srows)" \
  "INFO|stage_1e21_backfill_candidates|3|INFO|stage_1e21_backfill|rows|3|from|NULL:1,teknoloji_devi:1,yapay_zeka_lab:1|3|a=yapay_zeka_lab b=NULL c=teknoloji_devi d=yapay_zeka_lab e=mars_ofisi f=NULL"
check "I3 install without preflight / without dryrun in the run directory -> STOP (nothing installed)" \
  "$(ins i2 build >/dev/null; ins i2 install | tail -n1 | cut -c1-46)|$(ins i2 preflight >/dev/null; ins i2 install | tail -n1 | cut -c1-40)|$(fmd5 $DI)" \
  "STOP: preflight.out has no ^PREFLIGHT\|PASS in|STOP: dryrun.out has no ^DRYRUN\|PASS in|$B_MD5"
SNAP0=$(ssnap); r=""; for st in install verify; do r="$r $(ins i1 $st | tail -n1)"; done
check "I4 install / verify PASS; definition = v4.5" "$r|$(fmd5 $DI)" " INSTALL|PASS VERIFY|PASS|$V45_MD5"
check "S2 install: a b c -> asama_1e21 (backfill), d e f untouched; log = 3 backfill rows with the value before; revision / data / best_score / updated_at of every save unchanged" \
  "$(srows)|$(q $DI -c "select string_agg(right(user_id::text, 1) || '=' || coalesce(old_best_stage_id, 'NULL') || ':' || source, ' ' order by user_id) from kodhane_rule.stage_1e21_log")|$(ssnap)" \
  "a=asama_1e21 b=asama_1e21 c=asama_1e21 d=yapay_zeka_lab e=mars_ofisi f=NULL|a=yapay_zeka_lab:backfill b=NULL:backfill c=teknoloji_devi:backfill|$SNAP0"
check "S3 leaderboard v7 after the install: A B C listed with asama_1e21 (not yapay_zeka_lab)" "$(slb)" "A=asama_1e21 B=asama_1e21 C=asama_1e21 D=yapay_zeka_lab E=mars_ofisi"
DJ=$(q $DI -c "select sr_test.s21('asama_1e21', 1.149894005101156e21)::text")
r=$(qe $DI -c "select set_config('role', 'authenticated', false), set_config('request.jwt.claim.sub', '${SU}d', false)" \
      -c "update public.kodhane_saves set data = '$DJ'::jsonb, revision = revision + 1 where user_id = auth.uid() returning best_stage_id" | tail -n1)
q $DI -c "insert into public.kodhane_saves (user_id, data, revision) values ('${SU}9', '$DJ'::jsonb, 1)" >/dev/null
check "S4 player write (authenticated, JWT sub) of d at asama_1e21: CHECK accepts, B trigger sets asama_1e21, logged (old yapay_zeka_lab, trigger); new save 9 at asama_1e21 logged (old NULL, trigger)" \
  "$r|$(q $DI -c "select string_agg(right(user_id::text, 1) || '=' || coalesce(old_best_stage_id, 'NULL') || ':' || source, ' ' order by user_id) from kodhane_rule.stage_1e21_log where source = 'trigger'")" \
  "asama_1e21|9=NULL:trigger d=yapay_zeka_lab:trigger"
check "S5 CHECK still refuses an unknown stage id (asama_x, also with triggers off); verify PASS after the trigger writes" \
  "$(qe $DI -c "set session_replication_role = replica" -c "update public.kodhane_saves set best_stage_id = 'asama_x' where user_id = '${SU}f'" | grep -c 'kodhane_saves_best_stage_id_known')|$(q $DI -f - < "$SRV" | grep -E '^SRVERIFY')" "1|SRVERIFY|PASS|14"
q $DI -c "insert into auth.users (id, aud, role, created_at, updated_at) values ('${SU}8', 'authenticated', 'authenticated', now(), now())" \
      -c "insert into public.kodhane_saves (user_id, data, revision) values ('${SU}8', '$DJ'::jsonb, 1)" >/dev/null
r="$(q $DI -c "select count(*) from kodhane_rule.stage_1e21_log where user_id = '${SU}8'")"
q $DI -c "delete from auth.users where id = '${SU}8'" >/dev/null
check "S6 account deletion: deleting the user (auth.users -> kodhane_saves cascade) also removes its stage_1e21_log row (FK on delete cascade)" \
  "$r|$(q $DI -c "select count(*) from kodhane_rule.stage_1e21_log where user_id = '${SU}8'")|$(q $DI -c "select count(*) from public.kodhane_saves where user_id = '${SU}8'")" "1|0|0"
cp -r "$ROOT" "$OUT/sbcopy"; echo "-- changed" >> "$OUT/sbcopy/migrations/20261003080000_v4_5_kodhane_score_rule.sql"
check "I5 changed migration (md5 differs from inputs.md5) -> build STOP" "$(env KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$DI KODHANE_OUT="$OUT/i5" bash "$OUT/sbcopy/ops/kodhane_score_rule_install.sh" build 2>&1 | tail -n1 | cut -c1-59)" "STOP: input files differ from kodhane_score_rule/inputs.md5"
# a save that v4.4b (here: a stand-in that accepts everything) accepts and v4.5 refuses -> preflight STOP, dryrun nothing committed
DF=sr_fake; mkdb $DF || { echo "setup $DF failed"; exit 1; }
q $DF -c "create or replace function public.kodhane_score_plausible(d jsonb, p_now timestamptz default now()) returns boolean language sql stable set search_path to '' as \$f\$ select true \$f\$" \
      -c "comment on function public.kodhane_score_plausible(jsonb, timestamptz) is 'Kodhane leaderboard heuristic v4.4b (test stand-in: accepts everything)'" \
      -c "update public.kodhane_saves set revision = revision + 1, data = data || '{\"totalEarned\": 1e40, \"runEarned\": 1e40, \"cycleEarned\": 1e40}' where user_id = (select user_id from public.kodhane_saves order by user_id limit 1)" >/dev/null
r=$(env KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$DF KODHANE_OUT="$OUT/i6" bash "$INS" build >/dev/null 2>&1; env KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$DF KODHANE_OUT="$OUT/i6" bash "$INS" preflight 2>&1)
check "I6 a save plausible now but not under v4.5 -> preflight STOP (became_false 1)" "$(grep -oE 'became_false\|[0-9]+' <<< "$r")|$(tail -n1 <<< "$r" | cut -c1-28 | sed 's/ *$//')" "became_false|1|STOP: preflight did not pass"
echo "PREFLIGHT|PASS" > "$OUT/i6/preflight.out"   # forced: the transaction check must stop it on its own
r=$(env KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$DF KODHANE_OUT="$OUT/i6" bash "$INS" dryrun 2>&1)
check "I7 same with a forced preflight: dryrun stops in the transaction ('would become implausible'), nothing changed" \
  "$(grep -c 'would become implausible' "$OUT/i6/dryrun.out")|$(tail -n1 <<< "$r" | cut -c1-25)|$(q $DF -c "select to_regnamespace('kodhane_rule') is null")" "1|STOP: dryrun did not pass|t"
P -d postgres -c "drop database $DF with (force)" >/dev/null 2>&1

# ------------------------------------------------------------------ R rollback
check "R0 rollback without rollback-preview in the run directory -> STOP (nothing changed); rollback-preview records 5 rows (3 backfill, 2 trigger) in rollback_rows.tsv" \
  "$(ins i2 rollback | tail -n1 | cut -c1-50)|$(fmd5 $DI)|$(ins i1 rollback-preview | tail -n1 | cut -c1-29)|$(grep -E '^RBCOUNT' "$OUT/i1/rollback_preview.out")|$(sed 1d "$OUT/i1/rollback_rows.tsv" | wc -l)" \
  "STOP: rollback_preview.out has no ^RBPREVIEW\|PASS|$V45_MD5|RBPREVIEW|PASS|5 row(s) recor|RBCOUNT|5|backfill|3|trigger|2|nolog|0|5"
check "R0b rollback-preview: RBJIT says the rollback removes jit=off" "$(grep -E '^RBJIT' "$OUT/i1/rollback_preview.out")" 'RBJIT|search_path="",jit=off|rollback removes jit=off from kodhane_score_plausible (v4.4b definition: search_path only)'
SNAP1=$(ssnap)
r=$(ins i1 rollback | tail -n1)
check "R1 rollback (install script): ROLLBACK|PASS; definition = v4.4b ($B_MD5); stage catalogue + CHECK = B ($B_CAT); kodhane_rule gone; rows as preview, restored" \
  "$r|$(fmd5 $DI)|$(cmd5 $DI)|$(q $DI -c "select to_regnamespace('kodhane_rule') is null")|$(grep -E '^CHECK\|rollback_rows_restored' "$OUT/i1/rollback.out")|$(diff <(grep '^RBROW|' "$OUT/i1/rollback_preview.out") <(grep '^RBROW|' "$OUT/i1/rollback.out") >/dev/null && echo same)" \
  "ROLLBACK|PASS|$B_MD5|$B_CAT|t|CHECK|rollback_rows_restored|t|5|same"
# row by row from the file written BEFORE the rollback: each user_id now has its recorded value before
rowcheck() { local ok=0 n=0 line="" u now back src cur; while IFS=$'\t' read -r u now back src; do n=$((n+1))
    cur=$(q $DI -c "select coalesce(best_stage_id, 'NULL') from public.kodhane_saves where user_id = '$u'" < /dev/null)
    [[ "$cur" == "$back" && "$now" == asama_1e21 ]] && ok=$((ok+1)); line="$line ${u: -1}:$now>$cur"; done < <(sed 1d "$1"); echo "$ok/$n$line"; }
check "R1d after the rollback: no jit setting (proconfig search_path only), CHECK|rollback_no_jit_setting|t" "$(pcfg $DI)|$(grep -E '^CHECK\|rollback_no_jit_setting' "$OUT/i1/rollback.out")" 'search_path=""|CHECK|rollback_no_jit_setting|t'
check "R1b row by row (rollback_rows.tsv, written before the rollback): every recorded save back to its value before; e f untouched; revision / data / updated_at unchanged" \
  "$(rowcheck "$OUT/i1/rollback_rows.tsv")|$(srows)|$(ssnap)" \
  "5/5 9:asama_1e21>NULL a:asama_1e21>yapay_zeka_lab b:asama_1e21>NULL c:asama_1e21>teknoloji_devi d:asama_1e21>yapay_zeka_lab|9=NULL a=yapay_zeka_lab b=NULL c=teknoloji_devi d=yapay_zeka_lab e=mars_ofisi f=NULL|$SNAP1"
check "R1c leaderboard after the rollback: B's view again (A yapay_zeka_lab; asama_1e21 saves implausible under v4.4b; 9 keeps the best_score of its v4.5 write, legacy stage freelancer)" "$(slb)" "9=freelancer A=yapay_zeka_lab C=teknoloji_devi D=yapay_zeka_lab"
check "R2 verify after rollback -> STOP (not v4.5)" "$(ins i1 verify | tail -n1 | cut -c1-25)" "STOP: verify did not pass"
P -d $DI -f - < "$RBS" > "$OUT/r3.log" 2>&1
check "R3 rollback file a second time: no error, still v4.4b, 0 rows to restore" "$?|$(fmd5 $DI)|$(grep -oE 'RBCOUNT\|[0-9]+' "$OUT/r3.log")" "0|$B_MD5|RBCOUNT|0"
P -d $DI -f - < "$MIGS" > "$OUT/r4.log" 2>&1
check "R4 re-install after rollback: v4.5 again, verify PASS; backfill now 5 rows (9 a b c d at asama_1e21)" "$(fmd5 $DI)|$(q $DI -f - < "$SRV" | grep -E '^SRVERIFY')|$(grep -oE 'INFO\|stage_1e21_backfill\|.*' "$OUT/r4.log")|$(srows)" \
  "$V45_MD5|SRVERIFY|PASS|14|INFO|stage_1e21_backfill|rows|5|from|NULL:2,teknoloji_devi:1,yapay_zeka_lab:2|9=asama_1e21 a=asama_1e21 b=asama_1e21 c=asama_1e21 d=asama_1e21 e=mars_ofisi f=NULL"
check "R5 rollback file after the re-install: v4.4b + B catalogue, rows back again (row by row = rollback_rows.tsv)" \
  "$(P -d $DI -At -f - < "$RBS" > "$OUT/r5.log" 2>&1; fmd5 $DI)|$(cmd5 $DI)|$(rowcheck "$OUT/i1/rollback_rows.tsv" | cut -d' ' -f1)|$(grep -E '^CHECK\|rollback_rows_restored' "$OUT/r5.log")" \
  "$B_MD5|$B_CAT|5/5|CHECK|rollback_rows_restored|t|5"
check "R5b rollback file directly: proconfig search_path only (jit=off gone)" "$(pcfg $DI)" 'search_path=""'

for d in sr_main sr_ins; do P -d postgres -c "drop database if exists $d with (force)" >/dev/null 2>&1; done
s=""; for k in $(printf '%s\n' "${!NT[@]}" | sort); do s="$s $k ${NT[$k]},"; done
echo "== done: $PASSN pass / $FAILS fail (${s% ,}); image $(docker inspect -f '{{.Image}}' "$CT" | cut -c8-19); artefacts in $OUT"
exit $(( FAILS > 0 ))
