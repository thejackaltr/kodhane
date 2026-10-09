#!/usr/bin/env bash
# Kodhane loss report (Kayıp bildir, migration 20261003060000) tests. LOCAL THROWAWAY DATABASES ONLY, in the local docker
# container $LR_CT (supabase/postgres image) whose database $LR_BASE holds the live schema (v2.2, no data). Never point this
# at the live DB: it drops / creates databases, writes and deletes rows.
#   LR_CT=<container> bash supabase/tests/loss_report/run_kodhane_loss_report_tests.sh 2>&1 | tee /tmp/kd-lr-test.log
# Groups: M migration (prerequisites, idempotent, verify, as postgres, B / progress log untouched, with the deletion log),
# P privileges / RLS, C create RPC + limits, S status RPC, A approve / apply (approval required, idempotent, log row, backup,
# B guard, leaderboard), N needs_review (revision changed), V corrected amounts / score rule / reject, Q queue / timeline,
# K cleanup, D account deletion (preflight, both modes, verify, token, FK cascade, deletion log reapply), R rollback,
# I install package (kodhane_loss_report_install.sh, delete-script check, verify delete check), L HTTP via a local PostgREST image (SKIP if absent).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; OPS="$ROOT/ops"
CT="${LR_CT:-v44x-136}"; BASE="${LR_BASE:-v44_base}"; OUT="${LR_OUT:-/tmp/kd-lr-test}"; rm -rf "$OUT"; mkdir -p "$OUT"; chmod 700 "$OUT"
MIGA="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"; MIGB="$ROOT/migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql"
MIGL="$ROOT/migrations/20261003020000_v4_4_kodhane_progress_log.sql"; MIGD="$ROOT/migrations/20261003040000_v4_4_kodhane_deletion_log.sql"
MIGK="$ROOT/migrations/20261003060000_v4_5_kodhane_loss_report.sql"; RBK="$ROOT/rollback/20261003060000_v4_5_kodhane_loss_report.rollback.sql"
LRV="$OPS/kodhane_loss_report/install_verify.sql"; DLV="$OPS/kodhane_deletion_log/install_verify.sql"
DEL="$OPS/kodhane_account_delete.sql"; PRE="$OPS/kodhane_account_delete_preflight.sql"; VER="$OPS/kodhane_account_delete_verify.sql"
EXP="$OPS/kodhane_deletion_log_export.sh"; REA="$OPS/kodhane_deletion_log_reapply.sh"
U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222; U3=33333333-3333-4333-8333-333333333333
U4=44444444-4444-4444-8444-444444444444; U5=55555555-5555-4555-8555-555555555555
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
PA() { P -At -F '|' "$@"; }
FAILS=0; PASSN=0; declare -A NT=()
pass() { echo "PASS $*"; PASSN=$((PASSN+1)); local k=${1%%[0-9]*}; NT[$k]=$(( ${NT[$k]:-0} + 1 )); }
fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1  -- ${2:0:200}"; else fail "$1: got [$2] expected [$3]"; fi; }
q() { local d=$1; shift; PA -d "$d" "$@" 2>>"$OUT/stderr" | sed '/^$/d'; }
# as <db> <uid | anon | service | nouid> <sql returning one value>: run as that role (PostgREST-like)
as() { local who
  case $2 in anon) who="select t.login(null)";; service) who="select t.as_service()";;
             nouid) who="select set_config('role', 'authenticated', false), set_config('request.jwt.claim.sub', '', false)";;
             *) who="select t.login('$2')";; esac
  PA -d "$1" -c "$who" -c "$3" 2>>"$OUT/stderr" | tail -n 1; }
# err <db> <uid | admin | ...> <sql>: 'none' or SQLSTATE|message|detail
err() { local s=${3//\'/\'\'}; if [[ $2 == admin ]]; then q "$1" -c "select t.err('$s')"; else as "$1" "$2" "select t.err('$s')"; fi; }
code() { err "$@" | cut -d'|' -f1; }
dump() { docker exec "$CT" pg_dump -U supabase_admin --schema-only "$@" | grep -v '^\\\(un\)\?restrict '; }
mkdb() {   # mkdb <db> [no-b | no-pl]: base + A + B + progress log + seeds
  P -d postgres -c "drop database if exists $1 with (force)" -c "create database $1 template $BASE" >/dev/null 2>&1 || return 1
  P -d $1 -1 -f - < "$MIGA" >/dev/null 2>&1 || return 1
  [[ ${2:-} == no-b ]] || { P -d $1 -1 -f - < "$MIGB" >/dev/null 2>&1 || return 1; }
  [[ ${2:-} == no-pl ]] || { P -d $1 -f - < "$MIGL" >/dev/null 2>&1 || return 1; }
  P -d $1 -f - < "$ROOT/tests/fixtures/helpers.sql" >/dev/null && P -d $1 -f - < "$ROOT/tests/account_delete/seed.sql" >/dev/null || return 1
  [[ -n ${2:-} ]] && return 0
  P -d $1 -f - < "$ROOT/tests/progress_log/fixture.sql" >/dev/null && P -d $1 -f - < "$HERE/fixture.sql" >/dev/null || return 1
  P -d $1 -c "insert into auth.users (id, email) values ('$U5', 'u5-lr-test@example.invalid')" >/dev/null
}
lrv() { PA -d "$1" -f - < "$LRV" 2>&1 | grep -E '^LRVERIFY' ; }
dlv() { PA -d "$1" -f - < "$DLV" 2>&1 | grep -oE '^DLVERIFY\|[A-Z]+' ; }
pw() { as "$1" "$2" "select t.kw('$3'::jsonb)" >/dev/null; }          # player write (revision + 1)
rid() { q "$1" -c "select max(id) from kodhane_loss.loss_report where user_id = '$2'"; }
create() { as "$1" "$2" "select public.kodhane_loss_report_create($3)"; }
echo "== container $CT: $(docker inspect -f '{{.Config.Image}} {{.Image}}' "$CT" | cut -c1-90)"

# ------------------------------------------------------------------ M migration
mkdb lr_nob no-b || { echo "setup failed"; exit 1; }
P -d lr_nob -f - < "$MIGK" > "$OUT/m0a.log" 2>&1
check "M0a without package B: refused, nothing created" "$(grep -c 'package B (20260929204000) is not installed' "$OUT/m0a.log")|$(q lr_nob -c "select to_regnamespace('kodhane_loss') is null and to_regprocedure('public.kodhane_loss_report_status(integer)') is null")" "1|t"
mkdb lr_nopl no-pl || { echo "setup failed"; exit 1; }
P -d lr_nopl -f - < "$MIGK" > "$OUT/m0b.log" 2>&1
check "M0b without the progress log: refused, nothing created" "$(grep -c 'progress log (20261003020000) is not installed' "$OUT/m0b.log")|$(q lr_nopl -c "select to_regnamespace('kodhane_loss') is null")" "1|t"
P -d postgres -c "drop database lr_nob with (force)" -c "drop database lr_nopl with (force)" >/dev/null 2>&1

mkdb lr_main || { echo "setup lr_main failed"; exit 1; }
dump -d lr_main > "$OUT/main.pre.sql"
fdefs() { q "$1" -c "select md5(string_agg(p.proname || ':' || md5(pg_get_functiondef(p.oid)), ',' order by p.proname, p.oid)) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname not like 'kodhane\_loss\_report\_%'"; }
trg() { q "$1" -c "select string_agg(tgname || ':' || tgenabled, ',' order by tgname) from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and not tgisinternal"; }
F0=$(fdefs lr_main); T0=$(trg lr_main); PL0=$(q lr_main -c "select md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure))")
P -d lr_main -f - < "$MIGK" > "$OUT/m1.log" 2>&1 && pass "M1 migration applies (supabase_admin, own transaction, no -1)" || fail "M1 $(grep -m1 ERROR "$OUT/m1.log")"
dump -d lr_main > "$OUT/main.post1.sql"; P -d lr_main -f - < "$MIGK" > "$OUT/m2.log" 2>&1; dump -d lr_main > "$OUT/main.post2.sql"
diff -q "$OUT/main.post1.sql" "$OUT/main.post2.sql" >/dev/null && pass "M2 idempotent: second run OK, whole schema unchanged" || fail "M2 schema differs after a second run"
check "M3 install verify" "$(lrv lr_main)" "LRVERIFY|PASS|9"
check "M5 B / A / progress log untouched: other public function definitions, kodhane_saves triggers, kodhane_score_plausible md5" \
  "$(fdefs lr_main)|$(trg lr_main)|$(q lr_main -c "select md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure))")" "$F0|$T0|$PL0"
check "M5b public schema: only the two player RPCs are new" \
  "$(q lr_main -c "select string_agg(proname, ',' order by proname) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'kodhane\_loss\_report\_%'")|$(diff <(grep -E '^CREATE (TABLE|VIEW|TRIGGER)' "$OUT/main.pre.sql") <(grep -E '^CREATE (TABLE|VIEW|TRIGGER)' "$OUT/main.post1.sql") | grep -cE '^[<>] CREATE (TABLE|VIEW|TRIGGER) public\.')" \
  "kodhane_loss_report_create,kodhane_loss_report_status|0"
mkdb lr_pg || { echo "setup lr_pg failed"; exit 1; }
dump -d lr_pg > "$OUT/pg.pre.sql"
P -d postgres -c "alter database lr_pg owner to postgres" >/dev/null   # as live: database postgres is owned by postgres
docker exec -i "$CT" psql -U postgres -X -q -v ON_ERROR_STOP=1 -d lr_pg -f - < "$MIGK" > "$OUT/m4.log" 2>&1
check "M4 migration as role postgres (DevOps connects as postgres): applies, verify PASS" "$?|$(lrv lr_pg)" "0|LRVERIFY|PASS|9"
mkdb lr_dl || { echo "setup lr_dl failed"; exit 1; }
P -d lr_dl -f - < "$MIGD" >/dev/null 2>&1 && P -d lr_dl -f - < "$MIGK" > "$OUT/m6b.log" 2>&1
check "M6a deletion log first, then this migration: both install verifies PASS" "$(dlv lr_dl)|$(lrv lr_dl)" "DLVERIFY|PASS|LRVERIFY|PASS|9"

# ------------------------------------------------------------------ P privileges / RLS
D=lr_main
P -d $D -c "insert into kodhane_loss.loss_report (user_id, lost_items) values ('$U4', '{diger}')" >/dev/null   # a row to look for
r=""; for who in anon $U1 service; do for s in "perform count(*) from kodhane_loss.loss_report" "insert into kodhane_loss.loss_report (user_id, lost_items) values (auth.uid(), ''{diger}'')" "update kodhane_loss.loss_report set status = ''applied''" "delete from kodhane_loss.loss_report"; do
  r="$r $(as $D $who "select split_part(t.err('do \$x\$ begin $s; end \$x\$'), '|', 1)")"; done; done
check "P1 anon / authenticated / service_role: select, insert, update, delete on the table -> 42501 (no schema USAGE)" "$r" "$(printf ' 42501%.0s' {1..12})"
r=""; for who in anon $U1 service; do for f in "kodhane_loss.loss_report_queue()" "kodhane_loss.loss_report_apply(1, ''KD-TLF-2026-10-03-01'')" "kodhane_loss.loss_report_approve(1, ''KD-TLF-2026-10-03-01'')" "kodhane_loss.cleanup_loss_reports()"; do
  r="$r $(as $D $who "select split_part(t.err('select $f'), '|', 1)")"; done; done
check "P2 the same roles: ops functions (queue, apply, approve, cleanup) -> 42501" "$r" "$(printf ' 42501%.0s' {1..12})"
r="$(code $D anon "select public.kodhane_loss_report_create('{diger}')") $(code $D anon "select public.kodhane_loss_report_status()") $(code $D service "select public.kodhane_loss_report_create('{diger}')") $(code $D service "select public.kodhane_loss_report_status()") $(code $D nouid "select public.kodhane_loss_report_create('{diger}')") $(code $D nouid "select public.kodhane_loss_report_status()")"
check "P3 player RPCs: anon / service_role no EXECUTE; authenticated without a uid -> not_authenticated (all 42501)" "$r" "42501 42501 42501 42501 42501 42501"
r=$(PA -d $D -c begin -c "grant usage on schema kodhane_loss to authenticated" -c "grant select on kodhane_loss.loss_report to authenticated" -c "select t.login('$U4')" -c "select count(*) from kodhane_loss.loss_report" -c rollback | tail -n 1)
check "P4 RLS forced, no policy: even a mistaken GRANT shows the player 0 rows (own row exists)" "$r" "0"
r=$(PA -d $D -c begin -c "grant usage on schema kodhane_loss to service_role" -c "grant execute on function kodhane_loss.loss_report_queue(text), kodhane_loss.loss_report_assert_ops() to service_role" -c "select t.as_service()" -c "select t.err('select kodhane_loss.loss_report_queue()')" -c rollback | tail -n 1)
check "P5 a mistaken GRANT EXECUTE to service_role: the ops function still refuses (caller check)" "${r%%|*}|$(grep -c 'postgres / supabase_admin only' <<< "$r")" "42501|1"
P -d $D -c "delete from kodhane_loss.loss_report" >/dev/null

# ------------------------------------------------------------------ C create + limits (U2 main player: v4.4 save, a loss after 'u2_before')
pw $D $U2 '{"version": 5, "saveVersion": 5, "shares": 10, "prestigeCount": 10, "cycleRounds": 10, "tree": ["kod_1", "kod_2", "kod_3"]}'
q $D -c "select t.tmark('u2_before')" >/dev/null
pw $D $U2 '{"shares": 2, "tree": ["kod_1"]}'                     # the loss (e.g. an old tab)
R2REV=$(q $D -c "select revision from public.kodhane_saves where user_id = '$U2'")
# C14: lost_since as the client sends it (Frontend, A.2): Bugün / Dün = start of the player's LOCAL day as a UTC time, Son 7 /
# 30 gün = now - 7 / 30 days, Bilmiyorum = NULL. Each create in its own rolled-back transaction (no row, no rate limit).
tryc() { PA -d $D -c begin -c "select t.login('$U2')" -c "select coalesce(public.kodhane_loss_report_create('{diger}', $1) ->> 'status', 'x')" -c rollback 2>&1 | sed -n 2p; }
r=""; for e in "date_trunc('day', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul'" \
  "(date_trunc('day', now() at time zone 'Europe/Istanbul') - interval '1 day') at time zone 'Europe/Istanbul'" \
  "date_trunc('day', now() at time zone 'Pacific/Kiritimati') at time zone 'Pacific/Kiritimati'" \
  "(date_trunc('day', now() at time zone 'Pacific/Kiritimati') - interval '1 day') at time zone 'Pacific/Kiritimati'" \
  "date_trunc('day', now() at time zone 'Etc/GMT+12') at time zone 'Etc/GMT+12'" \
  "(date_trunc('day', now() at time zone 'Etc/GMT+12') - interval '1 day') at time zone 'Etc/GMT+12'" \
  "now() - interval '7 days'" "now() - interval '30 days'" "null" "to_char(now() at time zone 'UTC', 'YYYY-MM-DD\"T\"00:00:00.000\"Z\"')::timestamptz" \
  "now() + interval '4 minutes'" "now() - interval '364 days'"; do r="$r $(tryc "$e")"; done
check "C14 lost_since accepted: Bugün / Dün start in UTC+3, UTC+14 (Kiritimati), UTC-12; now - 7 / 30 days; NULL; ISO 'Z' text; +4 min clock skew; 364 days" \
  "$r" "$(printf ' in_review%.0s' {1..12})"
r="$(tryc "now() + interval '6 minutes'" ) $(tryc "now() - interval '366 days'")"
check "C14b lost_since 6 minutes ahead / 366 days back -> refused (loss_report_invalid)" "$r" "ERROR:  loss_report_invalid ERROR:  loss_report_invalid"
check "C14c the rolled-back tries left no report" "$(q $D -c "select count(*) from kodhane_loss.loss_report where user_id = '$U2'")" "0"
r=$(create $D $U2 "array['yatirim_turu', 'agac', 'agac'], (select t.at('u2_before')), E'  hisselerim\r\n gitti  ', '4.5.0'")
check "C1 create: id + status in_review" "$(jq -c '{status}' <<< "$r")|$(jq 'has("id") and has("created_at")' <<< "$r")" '{"status":"in_review"}|true'
R2=$(rid $D $U2)
check "C1b stored: uid, sorted distinct lost_items, lost_since, trimmed description (CRLF -> LF), client_version, save revision, status pending" \
  "$(q $D -c "select user_id || '|' || lost_items::text || '|' || (lost_since = t.at('u2_before')) || '|' || replace(description, E'\n', '\\n') || '|' || client_version || '|' || save_revision || '|' || status from kodhane_loss.loss_report where id = $R2")" \
  "$U2|{agac,yatirim_turu}|true|hisselerim\\n gitti|4.5.0|$R2REV|pending"
r=""; for a in "'{}'" "'{foo}'" "array['agac', null]" "null" "'{yatirim_turu,halka_arz,borsa_payi,agac,diger,x}'"; do r="$r $(err $D $U5 "select public.kodhane_loss_report_create($a)" | cut -d'|' -f1-3)"; done
check "C3 lost_items empty / unknown / NULL element / NULL / unknown 6th -> 22023 loss_report_invalid (lost_items)" "$r" "$(printf ' 22023|loss_report_invalid|lost_items%.0s' {1..5})"
r="$(err $D $U5 "select public.kodhane_loss_report_create('{diger}', now() + interval '1 hour')" | cut -d'|' -f1-3) $(err $D $U5 "select public.kodhane_loss_report_create('{diger}', now() - interval '400 days')" | cut -d'|' -f1-3)"
check "C4 lost_since in the future / older than 365 days -> 22023 (lost_since)" "$r" "22023|loss_report_invalid|lost_since 22023|loss_report_invalid|lost_since" 
r="$(err $D $U5 "select public.kodhane_loss_report_create('{diger}', null, repeat('a', 281))" | cut -d'|' -f1-3) $(err $D $U5 "select public.kodhane_loss_report_create('{diger}', null, 'mailim a@b.com')" | cut -d'|' -f1-3) $(err $D $U5 "select public.kodhane_loss_report_create('{diger}', null, E'a\\x01b')" | cut -d'|' -f1-3)"
check "C5 description > 280 / with @ (e-mail) / control character -> 22023 (description)" " $r" "$(printf ' 22023|loss_report_invalid|description%.0s' {1..3})" 
check "C7 no Kodhane cloud save -> PT404 no_cloud_save" "$(err $D $U5 "select public.kodhane_loss_report_create('{diger}')" | cut -d'|' -f1-2)" "PT404|no_cloud_save"
check "C8 a second report while one is open -> PT409 loss_report_open" "$(err $D $U2 "select public.kodhane_loss_report_create('{diger}')" | cut -d'|' -f1-2)" "PT409|loss_report_open"
check "C13 one open report per player is enforced by the DB too (direct insert -> 23505)" "$(code $D admin "insert into kodhane_loss.loss_report (user_id, lost_items) values ('$U2', '{diger}')")" "23505"
create $D $U1 "'{diger}', null, repeat('b', 280), '<script>'" >/dev/null; R1A=$(rid $D $U1)
check "C6 description of exactly 280 characters accepted; invalid client_version is not stored (NULL)" "$(q $D -c "select length(description) || '|' || coalesce(client_version, 'NULL') from kodhane_loss.loss_report where id = $R1A")" "280|NULL"
q $D -c "select kodhane_loss.loss_report_reject($R1A, 'diger')" >/dev/null
r=$(err $D $U1 "select public.kodhane_loss_report_create('{diger}')")
check "C10 after a rejection, within 24 hours -> PT429 loss_report_daily_limit, detail = retry time (created + 24 h, UTC)" \
  "$(cut -d'|' -f1-2 <<< "$r")|$(q $D -c "select to_char((created_at + interval '24 hours') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') from kodhane_loss.loss_report where id = $R1A" | sed 's/^/x/')" \
  "PT429|loss_report_daily_limit|x$(cut -d'|' -f3 <<< "$r")"
P -d $D -c "update kodhane_loss.loss_report set created_at = now() - interval '25 hours' where id = $R1A" >/dev/null
check "C11 25 hours later a new report is accepted" "$(create $D $U1 "'{halka_arz}'" | jq -r .status)" "in_review"
R1B=$(rid $D $U1)
P -d $D -c "insert into kodhane_loss.loss_report (user_id, lost_items, created_at, status, reject_reason) select '$U3', '{diger}', now() - make_interval(days => 2 + 5 * g), 'rejected', 'diger' from generate_series(0, 4) g" >/dev/null
check "C12 5 reports in 30 days (oldest 22 days ago) -> PT429 loss_report_monthly_limit" "$(err $D $U3 "select public.kodhane_loss_report_create('{diger}')" | cut -d'|' -f1-2)" "PT429|loss_report_monthly_limit"
P -d $D -c "update kodhane_loss.loss_report set created_at = now() - interval '31 days' where user_id = '$U3' and created_at < now() - interval '20 days'" >/dev/null
check "C12b with the oldest report 31 days back: accepted again" "$(create $D $U3 "'{diger}'" | jq -r .status)" "in_review"
R3=$(rid $D $U3)

# ------------------------------------------------------------------ S status RPC
check "S1 result columns: no description, no ops field; applied_revision last" "$(q $D -c "select pg_get_function_result('public.kodhane_loss_report_status(integer)'::regprocedure)")" \
  "TABLE(id bigint, created_at timestamp with time zone, lost_items text[], lost_since timestamp with time zone, status text, status_changed_at timestamp with time zone, reason text, applied_at timestamp with time zone, review_reason text, applied_revision bigint)"
check "S2 own reports only (U1 sees its 2, U2 its 1; ids match)" \
  "$(as $D $U1 "select string_agg(id::text || ':' || status || ':' || coalesce(reason, '-'), ',' order by id) from public.kodhane_loss_report_status()")/$(as $D $U2 "select string_agg(id::text || ':' || status, ',') from public.kodhane_loss_report_status()")" \
  "$R1A:rejected:diger,$R1B:in_review:-/$R2:in_review"
check "S3 p_limit clamped to 1..50 (0 -> 1 row, newest first)" "$(as $D $U1 "select string_agg(id::text, ',') from public.kodhane_loss_report_status(0)")" "$R1B"

# ------------------------------------------------------------------ A approve / apply (U2)
M0=$(q $D -c "select t.save_md5('$U2')"); O0=$(q $D -c "select t.others_md5('$U2')")
# rank / nickname / score / stage (+ stage_id): status may legitimately change when a restore makes the save plausible again
lbmd5() { q $D -c "select md5(coalesce((select json_agg(json_build_array(x.rank, x.nickname, x.score, x.stage, x.stage_id))::text from public.kodhane_leaderboard_v7(100) x), '') || coalesce((select json_agg(json_build_array(x.rank, x.nickname, x.score, x.stage))::text from public.kodhane_leaderboard(100, 'kodhane') x), ''))"; }
LB0=$(lbmd5)
check "A1 apply of a pending report -> 55000 'not approved', save untouched" "$(code $D admin "select kodhane_loss.loss_report_apply($R2, 'KD-TLF-2026-10-03-11')")|$(q $D -c "select t.save_md5('$U2')")" "55000|$M0"
r=""; for ref in "KD-TLF-2026-10-03-1@" "KD,TLF" 'KD"TLF-2026' 'KD\TLF-2026' "KD-TLF-2026-10-03-1"$'\x01' "KD-TLF-2026-13-01-01" "KD-TLF-2026-02-31-01" "" "KD-TLF-26-10-03-01"; do
  r="$r $(q $D -c "select split_part(t.err(format('select kodhane_loss.loss_report_approve($R2, %L, t.at(''u2_before''))', \$\$$ref\$\$)), '|', 1)")"; done
check "A2 approval_ref with @ , \" \\ control character / bad month / no real date / empty / wrong format -> 22023, still pending" \
  "$r|$(q $D -c "select status from kodhane_loss.loss_report where id = $R2")" "$(printf ' 22023%.0s' {1..9})|pending"
r=$(q $D -c "select kodhane_loss.loss_report_proposal($R2)")
check "A3 proposal (at lost_since): shares 2 -> 10, tree + kod_2, kod_3; other fields unchanged" \
  "$(jq -c '[.diff, .tree_add, .nothing_to_restore, .revision]' <<< "$r")" "[{\"tree\":{\"to\":3,\"from\":1},\"shares\":{\"to\":10,\"from\":2}},[\"kod_2\",\"kod_3\"],false,$R2REV]"
r=$(q $D -c "select kodhane_loss.loss_report_approve($R2, 'KD-TLF-2026-10-03-11', null, null, 'test onayı')")
check "A4 approve -> approved; approved values = only what changes; approved revision = save revision" \
  "$(jq -r .result <<< "$r")|$(q $D -c "select status || '|' || approved_values::text || '|' || (approved_revision = $R2REV) || '|' || (ref_at = t.at('u2_before')) from kodhane_loss.loss_report where id = $R2")" \
  'approved|approved|{"tree": ["kod_2", "kod_3"], "shares": 10}|true|true'
check "A4b approve again: same reference -> already_approved; another reference -> 55000 (only pending / needs_review)" \
  "$(q $D -c "select kodhane_loss.loss_report_approve($R2, 'KD-TLF-2026-10-03-11') ->> 'result'")|$(code $D admin "select kodhane_loss.loss_report_approve($R2, 'KD-TLF-2026-10-03-19')")" "already_approved|55000"
check "A4c player sees 'approved' (no ref, no values, applied_revision NULL)" "$(as $D $U2 "select status || '|' || coalesce(applied_at::text, '-') || '|' || coalesce(applied_revision::text, 'NULL') from public.kodhane_loss_report_status()")" "approved|-|NULL"
check "A5 apply with another approval_ref -> 42501, save untouched" "$(code $D admin "select kodhane_loss.loss_report_apply($R2, 'KD-TLF-2026-10-03-12')")|$(q $D -c "select t.save_md5('$U2')")" "42501|$M0"
q $D -c "select t.setmark()" >/dev/null
BS0=$(q $D -c "select best_score || '|' || best_stage || '|' || md5((data - array['shares', 'prestigeCount', 'cycleRounds', 'ipoCount', 'ipoShares', 'ipoSharesEarned', 'tree'])::text) || '|' || (data->>'saveVersion') from public.kodhane_saves where user_id = '$U2'")
r=$(q $D -c "select kodhane_loss.loss_report_apply($R2, 'KD-TLF-2026-10-03-11')")
check "A6 apply -> applied: shares 10, tree kod_1..3 back, revision + 1 (strict), log rows 3" \
  "$(jq -c '[.result, .revision_before, .revision_after, .log_rows]' <<< "$r")|$(q $D -c "select t.lf('$U2') || '|' || strict_revision from public.kodhane_saves where user_id = '$U2'")" \
  "[\"applied\",$R2REV,$((R2REV+1)),3]|10/10/10/0/0/0/[\"kod_1\", \"kod_2\", \"kod_3\"]|true"
check "A6b nothing else in the save changed (totalEarned, money, saveVersion ...), best_score / best_stage kept" \
  "$(q $D -c "select best_score || '|' || best_stage || '|' || md5((data - array['shares', 'prestigeCount', 'cycleRounds', 'ipoCount', 'ipoShares', 'ipoSharesEarned', 'tree'])::text) || '|' || (data->>'saveVersion') from public.kodhane_saves where user_id = '$U2'")" "$BS0"
check "A7 one 'manual' backup = the save before the restore (revision, payload)" \
  "$(q $D -c "select count(*) || '|' || bool_and(b.revision = $R2REV) || '|' || bool_and(b.payload ->> 'shares' = '2') || '|' || bool_and(b.id = r.backup_id) from public.kodhane_save_backups b join kodhane_loss.loss_report r on r.id = $R2 where b.user_id = '$U2' and b.reason = 'manual'")" "1|true|true|true"
check "A8 progress log: own telafi rows with the approval reference, actor supabase_admin" \
  "$(q $D -c "select t.since('$U2')")|$(q $D -c "select string_agg(distinct approval_ref || '/' || actor_role, ',') from public.kodhane_progress_log where id > (select id from t.mark)")" \
  "telafi:shares:2>10 telafi:tree:1>3:kod_2 telafi:tree:1>3:kod_3|KD-TLF-2026-10-03-11/supabase_admin"
M1=$(q $D -c "select t.save_md5('$U2')")
r=$(q $D -c "select kodhane_loss.loss_report_apply($R2, 'KD-TLF-2026-10-03-11')")
check "A9 second apply -> already_applied, save / backups / log identical, other players untouched" \
  "$(jq -r .result <<< "$r")|$(q $D -c "select t.save_md5('$U2')")|$(q $D -c "select t.others_md5('$U2')")" "already_applied|$M1|$O0"
check "A10 player sees 'applied' with applied_at; status_changed_at = applied_at; applied_revision = revision written by the restore" "$(as $D $U2 "select status || '|' || (applied_at is not null) || '|' || (applied_at = status_changed_at) || '|' || applied_revision from public.kodhane_loss_report_status()")" "applied|true|true|$((R2REV+1))"
check "A13 leaderboards (v7 + v6 kodhane: rank, nickname, score, stage) identical before / after the restore" "$(lbmd5)" "$LB0"
check "A14 applied report: approve -> 55000, reject -> 55000" "$(code $D admin "select kodhane_loss.loss_report_approve($R2, 'KD-TLF-2026-10-03-11')")|$(code $D admin "select kodhane_loss.loss_report_reject($R2, 'diger')")" "55000|55000"
r="$(as $D $U2 "select split_part(t.err('update public.kodhane_saves set data = data || ''{\"money\": 1}'', revision = $((R2REV+1)) where user_id = auth.uid()'), '|', 1)") $(as $D $U2 "select split_part(t.err('update public.kodhane_saves set data = data || ''{\"saveVersion\": 4}'', revision = $((R2REV+2)) where user_id = auth.uid()'), '|', 1)") $(as $D $U2 "select t.err('select t.kw(''{\"money\": 2}'')')")"
check "A11 after the restore: the old tab's write (old revision) -> PT409 stale_revision; older saveVersion -> PT426 (B); a normal write works" "$r" "PT409 PT426 none"

# ------------------------------------------------------------------ N needs_review (U4: the save changes between approval and apply)
pw $D $U4 '{"ipoCount": 1, "ipoShares": 3, "ipoSharesEarned": 3}'; q $D -c "select t.tmark('u4_before')" >/dev/null; pw $D $U4 '{"ipoShares": 0}'
create $D $U4 "'{borsa_payi}', (select t.at('u4_before'))" >/dev/null; R4=$(rid $D $U4)
q $D -c "select kodhane_loss.loss_report_approve($R4, 'KD-TLF-2026-10-03-21')" >/dev/null
pw $D $U4 '{"money": 5}'; M4=$(q $D -c "select t.save_md5('$U4')")
r=$(q $D -c "select kodhane_loss.loss_report_apply($R4, 'KD-TLF-2026-10-03-21')")
check "N1 save revision changed after the approval: apply -> needs_review, nothing written, review_count 1" \
  "$(jq -r .result <<< "$r")|$(q $D -c "select t.save_md5('$U4')")|$(q $D -c "select status || '|' || review_count from kodhane_loss.loss_report where id = $R4")" "needs_review|$M4|needs_review|1"
check "N1b player sees in_review + review_reason save_changed (no note, no reference, applied_revision NULL); status_changed_at = the re-review time" \
  "$(as $D $U4 "select status || '|' || coalesce(review_reason, '-') || '|' || coalesce(reason, '-') || coalesce(applied_revision::text, '') from public.kodhane_loss_report_status()")|$(q $D -c "select review_reason || '|' || (status_changed_at > created_at) from kodhane_loss.loss_report where id = $R4")" "in_review|save_changed|-|save_changed|true"
check "N1c apply again while needs_review -> 55000" "$(code $D admin "select kodhane_loss.loss_report_apply($R4, 'KD-TLF-2026-10-03-21')")" "55000"
check "N2 approve again with another reference -> 22023; with the same reference -> approved at the new revision" \
  "$(code $D admin "select kodhane_loss.loss_report_approve($R4, 'KD-TLF-2026-10-03-22')")|$(q $D -c "select kodhane_loss.loss_report_approve($R4, 'KD-TLF-2026-10-03-21') ->> 'result'")|$(q $D -c "select approved_revision = (select revision from public.kodhane_saves where user_id = '$U4') from kodhane_loss.loss_report where id = $R4")" \
  "22023|approved|t"
check "N2b after the second approval: player sees approved, review_reason NULL (only while in_review)" "$(as $D $U4 "select status || '|' || coalesce(review_reason, 'NULL') from public.kodhane_loss_report_status()")" "approved|NULL"
r=$(PA -d $D -c begin -c "select kodhane_loss.loss_report_apply($R4, 'KD-TLF-2026-10-03-21') ->> 'result'" -c "select coalesce(current_setting('kodhane.progress_event', true), 'x') || '/' || coalesce(current_setting('kodhane.progress_ref', true), 'x')" -c commit | tr '\n' ' ')
check "N3 apply -> applied; the telafi flag + reference are cleared right after the write (same transaction)" "$r" "applied / "
check "N3b ipoShares 0 -> 3 restored, one telafi row" "$(q $D -c "select data->>'ipoShares' from public.kodhane_saves where user_id = '$U4'")|$(q $D -c "select string_agg(field || ':' || old_value || '>' || new_value, ',') from public.kodhane_progress_log where user_id = '$U4' and event = 'telafi'")" '3|ipoShares:0>3'

# N4 no_cloud_save: approved, then the cloud save disappears (reset / deletion) -> needs_review no_cloud_save, nothing written
as $D $U5 "select t.ki(t.save0() || '{\"shares\": 1}')" >/dev/null; create $D $U5 "'{diger}'" >/dev/null; R5=$(rid $D $U5)
q $D -c "select kodhane_loss.loss_report_approve($R5, 'KD-TLF-2026-10-03-71', null, '{\"shares\": 2}', null, true)" >/dev/null
P -d $D -c "delete from public.kodhane_saves where user_id = '$U5'" >/dev/null
r=$(q $D -c "select kodhane_loss.loss_report_apply($R5, 'KD-TLF-2026-10-03-71')")
check "N4 save gone after the approval: apply -> needs_review, review_reason no_cloud_save; player sees in_review|no_cloud_save" \
  "$(jq -r '.result + "|" + .review_reason' <<< "$r")|$(as $D $U5 "select status || '|' || coalesce(review_reason, '-') from public.kodhane_loss_report_status()")" "needs_review|no_cloud_save|in_review|no_cloud_save"
r="$(code $D admin "update kodhane_loss.loss_report set review_reason = 'ekip_notu' where id = $R5") $(code $D admin "update kodhane_loss.loss_report set review_reason = null where id = $R5") $(code $D admin "update kodhane_loss.loss_report set review_reason = 'save_changed' where id = (select min(id) from kodhane_loss.loss_report where status = 'pending')")"
check "N5 CHECK: another review_reason value -> 23514; needs_review without a reason -> 23514; pending with a reason -> 23514" "$r" "23514 23514 23514"
q $D -c "select kodhane_loss.loss_report_reject($R5, 'kayip_bulunamadi')" >/dev/null
check "N6 rejected after a re-review: player sees rejected|kayip_bulunamadi|review_reason NULL|applied_revision NULL" "$(as $D $U5 "select status || '|' || reason || '|' || coalesce(review_reason, 'NULL') || '|' || coalesce(applied_revision::text, 'NULL') from public.kodhane_loss_report_status()")" "rejected|kayip_bulunamadi|NULL|NULL"

# ------------------------------------------------------------------ V corrected amounts, score rule, reject (U3: no lost_since)
pw $D $U3 '{"totalEarned": 600000000, "cycleEarned": 600000000, "runEarned": 200000000, "stage": 3}'   # a save the score rule accepts
check "V1 proposal without lost_since and without p_at -> 22023 (asks for p_at)" "$(err $D admin "select kodhane_loss.loss_report_proposal($R3)" | cut -d'|' -f1)|$(err $D admin "select kodhane_loss.loss_report_proposal($R3)" | grep -c 'pass p_at')" "22023|1"
r=""; for v in '{"money": 5}' '{"shares": -1}' '{"shares": "5"}' '{"shares": 1e51}' '{"tree": ["Kod 1"]}' '[]' '{}'; do r="$r $(code $D admin "select kodhane_loss.loss_report_approve($R3, 'KD-TLF-2026-10-03-31', null, '$v')")"; done
check "V2 p_values: unknown key / negative / string / > 1e50 / bad node id / array / empty -> 22023" "$r" "$(printf ' 22023%.0s' {1..7})"
check "V3 p_values not above the current save (shares 2 -> 1) -> 22023 nothing to restore" "$(err $D admin "select kodhane_loss.loss_report_approve($R3, 'KD-TLF-2026-10-03-31', null, '{\"shares\": 1}')" | grep -c 'nothing to restore')" "1"
check "V4 U3's save passes the score rule now; shares 1e6 would fail it -> 22023, still pending" \
  "$(q $D -c "select public.kodhane_score_plausible(data) from public.kodhane_saves where user_id = '$U3'")|$(err $D admin "select kodhane_loss.loss_report_approve($R3, 'KD-TLF-2026-10-03-31', null, '{\"shares\": 1000000}')" | grep -c 'score rule')|$(q $D -c "select status from kodhane_loss.loss_report where id = $R3")" "t|1|pending"
r=$(q $D -c "select kodhane_loss.loss_report_approve($R3, 'KD-TLF-2026-10-03-31', null, '{\"shares\": 1000000}', null, true)")
check "V5 with p_accept_implausible => true: approved, plausible_before t / after f recorded" "$(jq -c '[.result, .plausible_before, .plausible_after]' <<< "$r")" '["approved",true,false]'
check "V6 reject: unknown reason -> 22023; kayip_bulunamadi -> rejected; again -> already_rejected" \
  "$(code $D admin "select kodhane_loss.loss_report_reject($R3, 'nope')")|$(q $D -c "select kodhane_loss.loss_report_reject($R3, 'kayip_bulunamadi', 'test') ->> 'result'")|$(q $D -c "select kodhane_loss.loss_report_reject($R3, 'kayip_bulunamadi') ->> 'result'")" "22023|rejected|already_rejected"
check "V6b rejected report: apply -> 55000, approve -> 55000; player sees rejected + reason" \
  "$(code $D admin "select kodhane_loss.loss_report_apply($R3, 'KD-TLF-2026-10-03-31')")|$(code $D admin "select kodhane_loss.loss_report_approve($R3, 'KD-TLF-2026-10-03-31')")|$(as $D $U3 "select status || ':' || reason from public.kodhane_loss_report_status(1)")" "55000|55000|rejected:kayip_bulunamadi"
pw $D $U1 '{"shares": 3}'
check "V7 one reference per report: U1's report with U2's reference -> 23505" "$(code $D admin "select kodhane_loss.loss_report_approve($R1B, 'KD-TLF-2026-10-03-11', null, '{\"shares\": 4}')")" "23505"
r=$(q $D -c "select kodhane_loss.loss_report_approve($R1B, 'KD-TLF-2026-10-03-41', null, '{\"shares\": 4, \"tree\": [\"kod_1\"]}', null, true)")
check "V8 corrected amounts (no log needed): shares 3 -> 4 and tree + kod_1 approved and applied" \
  "$(jq -r .result <<< "$r")|$(q $D -c "select kodhane_loss.loss_report_apply($R1B, 'KD-TLF-2026-10-03-41') ->> 'result'")|$(q $D -c "select (data->>'shares') || (data->'tree')::text from public.kodhane_saves where user_id = '$U1'")" 'approved|applied|4["kod_1"]'

P -d $D -c "insert into kodhane_loss.loss_report (user_id, lost_items) values ('$U1', '{diger}')" >/dev/null; RX=$(rid $D $U1)
q $D -c "select kodhane_loss.loss_report_approve($RX, 'KD-TLF-2026-10-03-61', null, '{\"shares\": 99}', null, true)" >/dev/null
MX=$(q $D -c "select t.save_md5('$U1')")
r=$(PA -d $D -c begin -c "alter table public.kodhane_saves disable trigger kodhane_saves_z_progress_log" -c "select t.err('select kodhane_loss.loss_report_apply($RX, ''KD-TLF-2026-10-03-61'')')" -c rollback | tail -n 1)
check "A15 progress log trigger switched off (emergency switch): apply refuses (no telafi row), save untouched, still approved" \
  "$(grep -c 'wrote no telafi row' <<< "$r")|$(q $D -c "select t.save_md5('$U1')")|$(q $D -c "select status from kodhane_loss.loss_report where id = $RX")" "1|$MX|approved"
q $D -c "select kodhane_loss.loss_report_reject($RX, 'diger')" >/dev/null
# ------------------------------------------------------------------ Q queue / timeline, K cleanup
check "Q1 queue('open') empty now; queue('all') shows every report with description (ops view); bad status -> 22023" \
  "$(q $D -c "select count(*) from kodhane_loss.loss_report_queue()")|$(q $D -c "select count(*) = (select count(*) from kodhane_loss.loss_report) and bool_or(description = repeat('b', 280)) from kodhane_loss.loss_report_queue('all')")|$(code $D admin "select kodhane_loss.loss_report_queue('x')")" "0|t|22023"
check "Q2 timeline of U2's report: the loss rows and the telafi rows" "$(q $D -c "select string_agg(event || ':' || field, ',' order by log_id) filter (where event = 'telafi' or (field = 'shares' and new_value = 2 and created_at > t.at('u2_before'))) from kodhane_loss.loss_report_timeline($R2)")" "yatirim_turu:shares,telafi:shares,telafi:tree,telafi:tree"
P -d $D -c "update kodhane_loss.loss_report set status_changed_at = now() - interval '366 days' where id in ($R3, $R1A)" -c "insert into kodhane_loss.loss_report (user_id, lost_items, created_at, status_changed_at) values ('$U5', '{diger}', now() - interval '400 days', now() - interval '400 days')" >/dev/null
check "K1 cleanup: closed reports older than 12 months go (2), an old OPEN report stays" "$(q $D -c "select kodhane_loss.cleanup_loss_reports()")|$(q $D -c "select count(*) from kodhane_loss.loss_report where id in ($R3, $R1A)")|$(q $D -c "select count(*) from kodhane_loss.loss_report where user_id = '$U5' and status = 'pending'")" "2|0|1"

P -d $D -c "update kodhane_loss.loss_report set status_changed_at = now() - interval '11 months 28 days' where id = $R5" >/dev/null
check "K2 12 months, not 365 days: a closed report 11 months 28 days old stays; at 12 months + 1 day it goes" \
  "$(q $D -c "select kodhane_loss.cleanup_loss_reports()")|$(P -d $D -c "update kodhane_loss.loss_report set status_changed_at = now() - interval '12 months 1 day' where id = $R5" >/dev/null; q $D -c "select kodhane_loss.cleanup_loss_reports()")|$(q $D -c "select (kodhane_loss.cfg_loss_report() ->> 'retention_months') || '/' || (kodhane_loss.cfg_loss_report() ->> 'description_max')")" "0|1|12/280"
check "K3 status RPC review_reason over every row a player can see: only save_changed / no_cloud_save / NULL (U1: NULL)" "$(as $D $U1 "select coalesce(string_agg(distinct coalesce(review_reason, 'NULL'), ','), 'none') from public.kodhane_loss_report_status(50)")|$(q $D -c "select count(*) from kodhane_loss.loss_report where review_reason is not null and review_reason not in ('save_changed', 'no_cloud_save')")" "NULL|0"

# K4: daily retention (12 months), as the Dokploy task runs it (psql -U postgres inside the db container), on this test DB
P -d $D -f - < "$ROOT/migrations/20261001210000_v4_4_kodhane_audit_log_retention.sql" >/dev/null 2>&1
P -d $D -c "update kodhane_loss.loss_report set status_changed_at = now() - interval '13 months' where id = (select min(id) from kodhane_loss.loss_report where status in ('applied', 'rejected'))" >/dev/null
r=$(docker exec -i "$CT" sh -c "$(sed "s/-d postgres/-d $D/" "$OPS/kodhane_retention_dokploy_command_with_progress_log_and_loss_report.txt")" 2>&1); rc=$?
check "K4 Dokploy command with the loss report step (-U postgres, -d -> test DB): exit 0, loss_report_rows 1" "$rc|$(grep -E '^loss_report_rows' <<< "$r" | tr -d ' ')" "0|loss_report_rows|1"
P -d $D -c "update kodhane_loss.loss_report set status_changed_at = now() - interval '13 months' where id = (select min(id) from kodhane_loss.loss_report where status in ('applied', 'rejected'))" >/dev/null
r=$(docker exec -i -e KD_DB=$D "$CT" sh -s < "$OPS/kodhane_retention_daily.sh" 2>&1); rc=$?
check "K5 kodhane_retention_daily.sh step 6 (deletion log absent -> skipped, then loss reports): exit 0, 1 report deleted" \
  "$rc|$(grep -c 'deletion log skipped' <<< "$r")|$(grep -oE 'loss_report [0-9]+ closed' <<< "$r")" "0|1|loss_report 1 closed"

# ------------------------------------------------------------------ D account deletion
token() { PA -d "$1" -v uid="$2" -f - < "$PRE" 2>&1 | grep -E '^(OK|BLOCKED|STOP):' | awk -F'|' '{print $NF}'; }
del() { local db=$1 log=$2 mode=$3 u=$4 tok=${5:-}; [[ -n $tok ]] || tok=$(token $db $u); P -d "$db" -v mode=$mode -v uid=$u -v confirm_uid=$u -v approval_ref="TEST-LR-$mode" -v expect="$tok" -f - < "$DEL" > "$OUT/$log" 2>&1; }
ver() { P -d "$1" -v mode=$2 -v uid=$3 -f - < "$VER" > "$OUT/$4" 2>&1; }
lrn() { q "$1" -c "select count(*) from kodhane_loss.loss_report where user_id = '$2'"; }
mkdb lr_del && P -d lr_del -f - < "$MIGK" >/dev/null 2>&1 || { echo "setup lr_del failed"; exit 1; }
D=lr_del
for u in $U1 $U2 $U3; do create $D $u "'{diger}'" >/dev/null; done
P -d $D -c "update kodhane_loss.loss_report set status = 'rejected', reject_reason = 'diger', created_at = now() - interval '2 days'" >/dev/null
for u in $U1 $U3; do create $D $u "'{agac}'" >/dev/null; done
OTH=$(q $D -c "select md5(string_agg(row(r.*)::text, '|' order by id)) from kodhane_loss.loss_report r where user_id = '$U2'")
PA -d $D -v uid=$U3 -f - < "$PRE" > "$OUT/d1.out" 2>&1
check "D1 preflight lists kodhane_loss.loss_report (2 rows of u3), deleted in both modes" "$(grep -c '^kodhane|kodhane_loss.loss_report|user_id|2|delete|delete$' "$OUT/d1.out")" "1"
T3=$(token $D $U3); create $D $U3 "'{diger}'" >/dev/null 2>&1; P -d $D -c "insert into kodhane_loss.loss_report (user_id, lost_items, status, reject_reason) values ('$U3', '{diger}', 'rejected', 'diger')" >/dev/null
del $D d6.log kodhane_only $U3 "$T3"
check "D6 a report filed after the preflight changes the token -> delete refused, nothing deleted" "$?|$(grep -c 'changed since the preflight' "$OUT/d6.log")|$(lrn $D $U3)" "3|1|3"
del $D d2.log kodhane_only $U3
check "D2 kodhane_only delete: reports gone; own notice line; summary line unchanged" \
  "$?|$(lrn $D $U3)|$(grep -c 'kodhane_loss.loss_report 3 (Kayıp bildir reports, mode kodhane_only)' "$OUT/d2.log")|$(grep -cE 'kept: kodhane_profiles, auth user, audit log, Açık Ofis; kodhane_progress_log [0-9]+; deletion log not installed \(no row\)$' "$OUT/d2.log")" "0|0|1|1"
ver $D kodhane_only $U3 d3a.log; ra=$?
P -d $D -c "insert into kodhane_loss.loss_report (user_id, lost_items) values ('$U3', '{diger}')" >/dev/null; ver $D kodhane_only $U3 d3b.log; rb=$?
check "D3 verify kodhane_only: OK, then fails on a leftover report" "$ra|$rb|$(grep -c 'kodhane_loss.loss_report=1' "$OUT/d3b.log")" "0|3|1"
P -d $D -c "delete from kodhane_loss.loss_report where user_id = '$U3'" >/dev/null
del $D d4.log full $U1; rd=$?; ver $D full $U1 d4v.log
check "D4 full delete: reports gone, verify OK, notice line" "$rd|$?|$(lrn $D $U1)|$(grep -c 'kodhane_loss.loss_report 2 (Kayıp bildir reports, mode full)' "$OUT/d4.log")" "0|0|0|1"
check "D5 bystander u2's report unchanged" "$(q $D -c "select md5(string_agg(row(r.*)::text, '|' order by id)) from kodhane_loss.loss_report r where user_id = '$U2'")" "$OTH"
create $D $U4 "'{diger}'" >/dev/null; P -d $D -c "delete from auth.users where id = '$U4'" >/dev/null
check "D7 auth user deleted directly (dashboard / GoTrue): FK cascade removes the reports" "$(lrn $D $U4)" "0"
# D8 deletion log + restore: an old report of a kodhane_only-deleted player comes back with a backup -> reapply deletes it
D=lr_dl; XD="$OUT/dlx"; mkdir -p "$XD"; chmod 700 "$XD"
create $D $U3 "'{diger}'" >/dev/null
del $D d8.log kodhane_only $U3
check "D8a kodhane_only delete with the deletion log: reports gone, list row, notice line" "$?|$(lrn $D $U3)|$(q $D -c "select scope from kodhane_private.deletion_log where user_id = '$U3'")|$(grep -c 'kodhane_loss.loss_report 1' "$OUT/d8.log")" "0|0|kodhane|1"
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$D KODHANE_DL_DIR="$XD" bash "$EXP" > "$OUT/d8x.out" 2>&1
P -d $D -c "insert into kodhane_loss.loss_report (user_id, lost_items, created_at, status, reject_reason) values ('$U3', '{diger}', (select deleted_at - interval '1 day' from kodhane_private.deletion_log where user_id = '$U3'), 'rejected', 'diger')" >/dev/null
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$D KODHANE_OUT=$OUT/d8v KODHANE_DL_DIR="$XD" bash "$REA" verify > "$OUT/d8v.out" 2>&1; rv=$?
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$D KODHANE_OUT=$OUT/d8r KODHANE_DL_DIR="$XD" bash "$REA" reapply > "$OUT/d8r.out" 2>&1; rr=$?
check "D8b restored old report (before the deletion): reapply verify LEFT, reapply deletes it" \
  "$rv|$(grep -cE "^ENTRY\|$U3\|kodhane\|kodhane\|LEFT" "$OUT/d8v.out")|$rr|$(lrn $D $U3)|$(tail -n1 "$OUT/d8r.out")" "1|1|0|0|REAPPLY|PASS"
P -d $D -c "insert into kodhane_loss.loss_report (user_id, lost_items) values ('$U3', '{diger}')" >/dev/null
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$D KODHANE_OUT=$OUT/d8n KODHANE_DL_DIR="$XD" bash "$REA" reapply > "$OUT/d8n.out" 2>&1; rr=$?
check "D8c a report filed after the deletion (played again): newer, kept" "$rr|$(grep -cE "^ENTRY\|$U3\|kodhane\|newer" "$OUT/d8n.out")|$(lrn $D $U3)" "0|1|1"

# ------------------------------------------------------------------ R rollback
D=lr_pg
create $D $U2 "'{diger}'" >/dev/null; RP=$(rid $D $U2)
q $D -c "select kodhane_loss.loss_report_approve($RP, 'KD-TLF-2026-10-03-51', null, '{\"shares\": 7}', null, true)" >/dev/null; q $D -c "select kodhane_loss.loss_report_apply($RP, 'KD-TLF-2026-10-03-51')" >/dev/null
P -d $D -f - < "$RBK" > "$OUT/r1.log" 2>&1
check "R1 rollback with reports -> refused, nothing dropped" "$?|$(grep -c 'would be lost' "$OUT/r1.log")|$(lrv $D)" "3|1|LRVERIFY|PASS|9"
docker exec -i -e PGOPTIONS='-c kodhane.loss_report_allow_loss=on' "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 -d $D -f - < "$RBK" > "$OUT/r2.log" 2>&1; r=$?
dump -d $D > "$OUT/pg.post_rb.sql"
check "R2 rollback with allow_loss: schema identical to before the migration (kodhane_loss gone)" "$r|$(diff -q "$OUT/pg.pre.sql" "$OUT/pg.post_rb.sql" >/dev/null && echo same || echo differs)|$(q $D -c "select to_regnamespace('kodhane_loss') is null")" "0|same|t"
check "R6 rollback does not undo an applied restore: save + telafi log row stay" "$(q $D -c "select (data->>'shares') || '|' || (select count(*) from public.kodhane_progress_log where approval_ref = 'KD-TLF-2026-10-03-51') from public.kodhane_saves where user_id = '$U2'")" "7|1"
P -d $D -f - < "$RBK" > "$OUT/r3.log" 2>&1; check "R3 rollback again (nothing left): OK" "$?" "0"
del $D r4.log kodhane_only $U3
check "R4 account delete after the rollback: works, no loss report line (old behaviour)" "$?|$(grep -c 'loss_report' "$OUT/r4.log")" "0|0"
P -d $D -f - < "$MIGK" > "$OUT/r5.log" 2>&1; check "R5 install again after the rollback: verify PASS" "$?|$(lrv $D)" "0|LRVERIFY|PASS|9"
D=lr_main
P -d $D -f - < "$MIGD" >/dev/null 2>&1
check "M6b deletion log installed AFTER this migration: both verifies PASS" "$(dlv $D)|$(lrv $D)" "DLVERIFY|PASS|LRVERIFY|PASS|9"
docker exec -i -e PGOPTIONS='-c kodhane.loss_report_allow_loss=on' "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 -d $D -f - < "$RBK" > "$OUT/r7.log" 2>&1
check "R7 rollback with the deletion log installed: kodhane_loss gone, kodhane_private.deletion_log untouched, its verify PASS" \
  "$?|$(q $D -c "select to_regnamespace('kodhane_loss') is null")|$(q $D -c "select string_agg(relname, ',' order by relname) from pg_class where relnamespace = 'kodhane_private'::regnamespace and relkind = 'r'")|$(dlv $D)|$(q $D -c "select count(*) from pg_proc where proname like 'kodhane\_loss\_report%' or proname like 'loss\_report%'")" "0|t|deletion_log|DLVERIFY|PASS|0"

# ------------------------------------------------------------------ I install package (kodhane_loss_report_install.sh) + delete-script guard
INS="$OPS/kodhane_loss_report_install.sh"; mkdb lr_i no-seed >/dev/null 2>&1 || mkdb lr_i || { echo "setup lr_i failed"; exit 1; }
ins() { local o=$1; shift; env KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=lr_i KODHANE_OUT="$OUT/$o" "$@" bash "$INS" "${STEP_:-}" 2>&1; }
r=""; for st in build preflight dryrun; do r="$r $(STEP_=$st ins ins1 | grep -E '^(BUILD|PREFLIGHT|DRYRUN)\|PASS' | tail -n1)"; done
check "I1 build / preflight / dryrun PASS (dry run leaves no kodhane_loss)" "$r|$(q lr_i -c "select to_regnamespace('kodhane_loss') is null")" " BUILD|PASS PREFLIGHT|PASS DRYRUN|PASS|t"
r=""; for st in install verify; do r="$r $(STEP_=$st ins ins1 | tail -n1)"; done
check "I2 install / verify PASS (9 checks + delete path: account delete preflight lists kodhane_loss.loss_report delete|delete)" "$r|$(grep -c '^CHECK|delete_path|t' <<< "$(STEP_=verify ins ins1)")" " INSTALL|PASS VERIFY|PASS|1"
# the account delete files BEFORE the loss report (v4.4, package B = dev before this branch): test fixture
# tests/loss_report/fixtures/pre_v45_account_deletion/ (byte for byte the four files of dev / v4.4 B; no git history needed).
# OLDOK=1 only if all four exist with exactly these md5s: a missing, empty or different fixture file makes I3 and I6 FAIL
# (never pass on empty files).
OLD_REV="pre-v4.5 fixture"; OLD_SRC="$HERE/fixtures/pre_v45_account_deletion"; OLD="$OUT/old_ops"; rm -rf "$OLD"; mkdir -p "$OLD/kodhane_deletion_log"; OLDOK=1
while read -r m f; do
  cp "$OLD_SRC/$f" "$OLD/$f" 2>>"$OUT/stderr" || OLDOK=0
  [[ -s "$OLD/$f" && "$(md5sum < "$OLD/$f" | cut -c1-32)" == "$m" ]] || OLDOK=0
done <<'OLDMD5'
28f379a49cc799f21cdee108999e5d8b kodhane_account_delete.sql
5a3bbf00538c2f4910f03031868bd4fe kodhane_account_delete_preflight.sql
7cf7132c74a9cd18c753edb48d8e54dc kodhane_account_delete_verify.sql
90f3e6c5a9fbaa1efdacf3d4abcbcf0e kodhane_deletion_log/reapply.sql
OLDMD5
r=""; for st in delete-script-check build preflight verify; do r="$r $(STEP_=$st ins ins2 KODHANE_ACCOUNT_DELETE_DIR="$OLD" | grep -cE '^STOP: delete-script-check failed$|^STOP: the account delete script' | sed 's/^2$/1/')"; done
check "I3 old ($OLD_REV, 4 files present with the expected md5) account delete script as KODHANE_ACCOUNT_DELETE_DIR: delete-script-check / build / preflight / verify STOP (4 md5 + 2 marker failures)" "old_files_ok=$OLDOK|$r|$(STEP_=delete-script-check ins ins2 KODHANE_ACCOUNT_DELETE_DIR="$OLD" | grep -c '^DELETECHECK|FAIL')" "old_files_ok=1| 1 1 1 1|6"
# I5 / I6: the verify's delete check (behaviour, one transaction, ROLLBACK): this branch's account delete -> PASS 5; the old
# (pre-v4.5 fixture) DO block put into the same generated SQL -> kodhane_only + full + cleanup fail, the FK cascade (3) still passes
LRN0=$(q lr_i -c "select count(*) || ':' || (select count(*) from auth.users) from kodhane_loss.loss_report")
v=$(STEP_=verify ins ins1)
check "I5 verify delete check: both modes (real DO block) + FK cascade + cleanup then delete, each undone -> DELCHECK|PASS|5; nothing stays" \
  "$(grep -c '^CHECK|delcheck_[1-5]|t|' <<< "$v")|$(grep -E '^DELCHECK\|PASS' <<< "$v")|$(q lr_i -c "select count(*) || ':' || (select count(*) from auth.users) from kodhane_loss.loss_report")|$(tail -n1 <<< "$v")" "5|DELCHECK|PASS|5|$LRN0|VERIFY|PASS"
python3 - "$OUT/ins1/sql/delete_check.sql" "$OLD/kodhane_account_delete.sql" "$OUT/delete_check_old.sql" <<'PYOLD'
import sys
g = open(sys.argv[1]).read().split('\n'); o = open(sys.argv[2]).read().split('\n')
fb = g.index('create or replace function pg_temp.kodhane_del_run() returns void language plpgsql as $del$'); fe = g.index('end $del$;', fb)
ob = o.index('do $del$'); oe = o.index('end $del$;')
open(sys.argv[3], 'w').write('\n'.join(g[:fb + 1] + o[ob + 1:oe + 1] + g[fe + 1:]))
PYOLD
r=$(P -d lr_i -At -f - < "$OUT/delete_check_old.sql" 2>&1)
check "I6 same delete check with the OLD ($OLD_REV) account delete block: DELCHECK|FAIL (kodhane_only leaves reports, full BLOCKED, cleanup + delete leaves one), FK cascade passes, rolled back" \
  "old_files_ok=$OLDOK|$(grep -E '^DELCHECK\|FAIL' <<< "$r")|$(grep -c '^CHECK|delcheck_3|t|' <<< "$r")|$(grep -c '^CHECK|delcheck_2|f|.*BLOCKED' <<< "$r")|$(q lr_i -c "select count(*) || ':' || (select count(*) from auth.users) from kodhane_loss.loss_report")" \
  "old_files_ok=1|DELCHECK|FAIL|delcheck_1,delcheck_2,delcheck_4|1|1|$LRN0"
mkdir -p "$OUT/new_ops"; cp "$OPS"/kodhane_account_delete*.sql "$OUT/new_ops/"; cp -r "$OPS/kodhane_deletion_log" "$OUT/new_ops/"
check "I4 unchanged copy of this branch's files -> PASS; one changed byte (md5 differs) -> STOP" "$(rm -f "$OUT/new_ops/x"; cp "$OPS/kodhane_account_delete.sql" "$OUT/new_ops/"; STEP_=delete-script-check ins ins3 KODHANE_ACCOUNT_DELETE_DIR="$OUT/new_ops" | tail -n1 | cut -d'|' -f1-2)|$(echo "-- changed" >> "$OUT/new_ops/kodhane_account_delete.sql"; STEP_=delete-script-check ins ins3 KODHANE_ACCOUNT_DELETE_DIR="$OUT/new_ops" | grep -c '^STOP:')" "DELETECHECK|PASS|1"
P -d postgres -c "drop database if exists lr_i with (force)" >/dev/null 2>&1

# ------------------------------------------------------------------ L HTTP (PostgREST, local image only; LR_HTTP=0 to leave out)
if [[ "${LR_HTTP:-1}" == 1 ]]; then
  mkdb lr_http && P -d lr_http -f - < "$MIGK" >/dev/null 2>&1 || { echo "setup lr_http failed"; exit 1; }
  bash "$HERE/http_loss_report.sh" "$CT" lr_http > "$OUT/http.txt" 2>&1
  while IFS= read -r l; do case $l in "PASS "*) pass "${l#PASS }";; "FAIL "*) fail "${l#FAIL }";; "SKIP "*) echo "$l"; LSKIP=1;; esac; done < "$OUT/http.txt"
  [[ -n "${LSKIP:-}" ]] || grep -q '^PASS L' "$OUT/http.txt" || fail "L HTTP tests did not run ($(head -c 200 "$OUT/http.txt"))"
  P -d postgres -c "drop database if exists lr_http with (force)" >/dev/null 2>&1
fi

for d in lr_main lr_pg lr_del lr_dl; do P -d postgres -c "drop database if exists $d with (force)" >/dev/null 2>&1; done
s=""; for k in $(printf '%s\n' "${!NT[@]}" | sort); do s="$s $k ${NT[$k]},"; done
echo "== done: $PASSN pass / $FAILS fail (${s% ,})${LSKIP:+; HTTP SKIPPED (image not local)}; image $(docker inspect -f '{{.Image}}' "$CT" | cut -c8-19); artefacts in $OUT"
[[ $FAILS -eq 0 ]]
