#!/usr/bin/env bash
# v2.2 HTTP-layer tests (PostgREST + GoTrue through Kong) against a LOCAL Supabase stack ONLY.
#
#   env (from `supabase status -o env` of the local stack; never commit them):
#     API_URL (http://127.0.0.1:54321)  ANON_KEY  SERVICE_ROLE_KEY  DB_URL (postgresql://postgres:…@127.0.0.1:54322/postgres)
#   usage: API_URL=… ANON_KEY=… SERVICE_ROLE_KEY=… DB_URL=… bash supabase/tests/http/run_http_tests.sh
#   (run_with_local_stack.sh starts a throw-away stack, exports these, runs this file and stops the stack.)
#
# Refuses any non-local URL. Resets ONLY the game objects in the local DB's public schema + its own test users, so it can
# be re-run. Runbook order (docs/v2.2-runbook.md): preflight -> Kodhane file -> Açık Ofis file -> verify, then the Açık
# Ofis (phase A) and Kodhane (phase B) HTTP checks, then the rollbacks in reverse order (phase C).
# Prints one line per check; exit 1 on any failure.
set -uo pipefail
: "${API_URL:?}" "${ANON_KEY:?}" "${SERVICE_ROLE_KEY:?}" "${DB_URL:?}"
for u in "$API_URL" "$DB_URL"; do
  [[ "$u" =~ ^[a-z]+://([^@/]*@)?(127\.0\.0\.1|localhost)(:[0-9]+)?(/|$) ]] || { echo "refusing non-local target: ${u%%\?*}" | sed -E 's#//[^@]*@#//***@#'; exit 2; }
done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
MIG_K="$ROOT/supabase/migrations/20260928160000_v2_2_kodhane_save_safety.sql"
MIG_A="$ROOT/supabase/migrations/20260928160100_v2_2_acik_ofis_save_safety.sql"
RB_K="$ROOT/supabase/rollback/20260928160000_v2_2_kodhane_save_safety.rollback.sql"
RB_A="$ROOT/supabase/rollback/20260928160100_v2_2_acik_ofis_save_safety.rollback.sql"
OPS="$ROOT/supabase/ops"
PRE="$ROOT/supabase/tests/fixtures/pre_v2_2_schema.sql"
LOG=${HTTP_LOG:-/tmp/v22-http/results.tsv}; mkdir -p "$(dirname "$LOG")"; : > "$LOG"
PASS=0; FAIL=0
db() { psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }
ok() {  # name cond [info]
  if [[ "$2" == 1 ]]; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; printf '%s\ttrue\t%s\n' "$1" "${3:-}" >> "$LOG"
  else FAIL=$((FAIL+1)); printf 'FAIL %s  [%s]\n' "$1" "${3:-}"; printf '%s\tfalse\t%s\n' "$1" "${3:-}" >> "$LOG"; fi
}
is() { if eval "$1"; then echo 1; else echo 0; fi; }
# req METHOD PATH TOKEN(anon|u1|u2|service) [BODY] [extra header…]  -> $CODE, $BODY
req() {
  local m=$1 p=$2 who=$3 body=${4:-} tok; shift 4 || shift $#
  case $who in anon) tok=$ANON_KEY;; service) tok=$SERVICE_ROLE_KEY;; u1) tok=$T1;; u2) tok=$T2;; esac
  local args=(-s -o /tmp/v22-http/body -w '%{http_code}' -X "$m" "$API_URL$p" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json')
  for h in "$@"; do args+=(-H "$h"); done
  [[ -n "$body" ]] && args+=(--data "$body")
  CODE=$(curl "${args[@]}"); BODY=$(cat /tmp/v22-http/body)
}
j() { jq -r "$1" <<<"$BODY" 2>/dev/null; }
MAP=()   # "error code -> HTTP status" observations
seen() { MAP+=("$1 -> HTTP $CODE ($2)"); }

reset_db() {
  db <<'SQL' >/dev/null
do $$ declare r record; begin
  for r in select format('drop table if exists public.%I cascade', tablename) q from pg_tables where schemaname = 'public' loop execute r.q; end loop;
  for r in select format('drop function if exists %s cascade', p.oid::regprocedure) q from pg_proc p where p.pronamespace = 'public'::regnamespace loop execute r.q; end loop;
end $$;
delete from auth.users where email like '%@v22-http.invalid';
SQL
}
echo "== reset local game objects, apply pre-v2.2 (kodhane-cloud schema + acik_ofis + leaderboard v5), then the runbook order"
reset_db
db -f "$PRE" >/dev/null 2>&1 || { echo "pre-v2.2 schema failed"; exit 1; }
out=$(db -f "$OPS/v2_2_preflight.sql" 2>&1 >/tmp/v22-http/fp.before); ok "P1 preflight: target ok (shared DB)" "$(is '[[ "$out" == *"target ok"* ]]')" "$out"
out=$(db -1 -f "$MIG_K" 2>&1); ok "P2 Kodhane migration (psql -1)" "$(is '[[ "$out" != *ERROR* ]]')" "$(grep -m1 ERROR <<<"$out")"
out=$(db -1 -f "$MIG_A" 2>&1); ok "P3 Açık Ofis migration after Kodhane: no shim, v6 kept" "$(is '[[ "$out" == *"no shim needed"* && "$out" != *ERROR* ]]')" "$(grep -m1 ERROR <<<"$out")"
out=$(db -f "$OPS/v2_2_verify.sql" 2>&1); ok "P4 v2_2_verify.sql: VERIFY OK 18/18" "$(is '[[ "$out" == *"VERIFY OK: 18/18"* ]]')" "$(grep -m3 -E "\|f\||ERROR" <<<"$out")"
db -f "$OPS/v2_2_fingerprint.sql" > /tmp/v22-http/fp.after
ok "P5 fingerprint unchanged by the migrations" "$(is 'cmp -s /tmp/v22-http/fp.before /tmp/v22-http/fp.after')"
db -c "notify pgrst, 'reload schema'" >/dev/null; sleep 2

user() {  # email -> access token (admin create + password grant)
  local pw="pw-$RANDOM-$RANDOM-x"
  req POST /auth/v1/admin/users service "{\"email\":\"$1\",\"password\":\"$pw\",\"email_confirm\":true}" >/dev/null
  [[ $CODE == 200 || $CODE == 201 ]] || { echo "admin create $1 -> $CODE" >&2; return 1; }
  local uid; uid=$(j .id)
  req POST '/auth/v1/token?grant_type=password' anon "{\"email\":\"$1\",\"password\":\"$pw\"}"
  echo "$uid $(j .access_token)"
}
read -r U1 T1 < <(user u1@v22-http.invalid); read -r U2 T2 < <(user u2@v22-http.invalid)
ok "A1 two real GoTrue users with access-token JWTs" "$(is '[[ -n "$T1" && -n "$T2" && "$T1" == *.*.* ]]')"

save() {  # totalEarned stage -> Açık Ofis save json
  printf '{"v":2,"startedAt":%s,"lastSaved":%s,"totalEarned":%s,"money":%s,"stage":%s,"playSec":%s,"simSec":%s,"desks":[{"id":1}],"staff":[],"items":[]}' \
    "$(( $(date +%s) * 1000 - 172800000 ))" "$(( $(date +%s) * 1000 ))" "$1" "$1" "$2" 86400 86400
}
row() { echo "{\"user_id\":\"$1\",\"data\":$2,\"save_version\":2,\"updated_at\":\"$(date -u +%FT%TZ)\"${3:+,\"revision\":$3}}"; }
UPSERT=(-H 'Prefer: resolution=merge-duplicates,return=minimal')
up() { req POST '/rest/v1/acik_ofis_saves?on_conflict=user_id' "$1" "$2" 'Prefer: resolution=merge-duplicates,return=minimal'; }
pull() { req GET "/rest/v1/acik_ofis_saves?select=data,save_version,updated_at,revision,best_score,best_stage,strict_revision&user_id=eq.$2" "$1"; }

echo "== phase A: Açık Ofis over HTTP (both files applied)"
req POST /rest/v1/kodhane_profiles u1 "{\"user_id\":\"$U1\",\"nickname\":\"Http Bir\"}" 'Prefer: return=minimal'
ok "A2 nickname in kodhane_profiles (what the v2.2 Açık Ofis client still uses)" "$(is '[[ $CODE == 201 ]]')" "$CODE"
up u1 "$(row "$U1" "$(save 50000 1)")"
ok "A3 old-client upsert (merge-duplicates, no revision) of real progress" "$(is '[[ $CODE == 201 ]]')" "$CODE $BODY"
up u1 "$(row "$U1" '{"v":2,"totalEarned":0,"money":0,"desks":[{"id":1}]}')"
ok "A4 late empty save from an old client -> 409 PT409 stale_write" "$(is '[[ $CODE == 409 && $(j .code) == PT409 && $(j .message) == stale_write ]]')" "$CODE $BODY"; seen PT409 stale_write
pull u1 "$U1"; R=$(j '.[0].revision')
ok "A5 v2.2 pull: row intact (50000), revision/best_score/best_stage readable, lenient" "$(is '[[ $CODE == 200 && $(j ".[0].data.totalEarned") == 50000 && $(j ".[0].best_score") == 50000 && $(j ".[0].best_stage") == 1 && $(j ".[0].strict_revision") == false ]]')" "$CODE rev=$R"
up u1 "$(row "$U1" "$(save 60000 1)" $((R+1)))"; ok "A6 v2.2 push with revision = server + 1 accepted (upsert on an existing row -> 200)" "$(is '[[ $CODE == 200 ]]')" "$CODE $BODY"
up u1 "$(row "$U1" "$(save 61000 1)" $((R+1)))"
ok "A7 same revision again on a strict row -> 409 PT409 stale_revision" "$(is '[[ $CODE == 409 && $(j .code) == PT409 && $(j .message) == stale_revision ]]')" "$CODE $BODY"; seen PT409 stale_revision
up u1 "$(row "$U1" "$(save 99000 1)" "$R")"
ok "A8 lower revision -> 409 stale_revision" "$(is '[[ $CODE == 409 && $(j .message) == stale_revision ]]')" "$CODE"
# two devices: B (same account) writes progress, A comes back with its old L + 1
L=$((R+1)); up u1 "$(row "$U1" "$(save 250000 2)" $((L+1)))"; ok "A9 device B writes progress (L + 1)" "$(is '[[ $CODE == 200 ]]')" "$CODE"
up u1 "$(row "$U1" "$(save 65000 1)" $((L+1)))"
ok "A10 device A back online with its old L + 1 -> 409 (B's progress kept)" "$(is '[[ $CODE == 409 ]]')" "$CODE $BODY"
pull u1 "$U1"; ok "A11 row = B's save (250000, stage 2)" "$(is '[[ $(j ".[0].data.totalEarned") == 250000 && $(j ".[0].best_stage") == 2 ]]')" "$BODY"
REV_BEFORE=$(j '.[0].revision')
req POST /rest/v1/rpc/acik_ofis_reset_save u1 '{}'
ok "A12 rpc/acik_ofis_reset_save {} -> 200 {backup_id,best_score,best_stage,revision} (no game field)" "$(is '[[ $CODE == 200 && $(j "keys|join(\",\")") == backup_id,best_score,best_stage,revision && $(j .revision) == $((REV_BEFORE+1)) && $(j .best_score) == 250000 && $(j .best_stage) == 2 ]]')" "$CODE $BODY"
BID=$(j .backup_id); L=$(( $(j .revision) > REV_BEFORE+1 ? $(j .revision) : REV_BEFORE+1 ))   # client: max(returned, L + 1)
pull u1 "$U1"; ok "A13 after reset: progress cleared, best_score/best_stage kept, row strict" "$(is '[[ $(j ".[0].data.totalEarned") == 0 && $(j ".[0].best_score") == 250000 && $(j ".[0].strict_revision") == true && $(j ".[0].revision") == $L ]]')"
req POST /rest/v1/rpc/kodhane_leaderboard anon '{"p_limit":50,"p_game":"acik_ofis"}'
ok "A14 anon rpc/kodhane_leaderboard(acik_ofis) after reset: score = best_score 250000, stage 2 (kodhane_leaderboard v6)" "$(is '[[ $CODE == 200 && $(j "map(select(.nickname==\"Http Bir\"))[0].score") == 250000 && $(j "map(select(.nickname==\"Http Bir\"))[0].stage") == 2 ]]')" "$CODE $BODY"
req POST /rest/v1/rpc/acik_ofis_list_save_backups u1 '{}'
ok "A15 rpc/acik_ofis_list_save_backups -> the reset backup (score 250000, stage 2)" "$(is '[[ $CODE == 200 && $(j ".[0].id") == $BID && $(j ".[0].reason") == reset && $(j ".[0].score") == 250000 ]]')" "$CODE"
req POST /rest/v1/rpc/acik_ofis_restore_save u2 "{\"p_backup_id\":\"$BID\"}"
ok "A16 other user restores u1's backup -> 404 PT404 backup_not_found" "$(is '[[ $CODE == 404 && $(j .code) == PT404 && $(j .message) == backup_not_found ]]')" "$CODE $BODY"; seen PT404 backup_not_found
req POST /rest/v1/rpc/acik_ofis_restore_save u1 "{\"p_backup_id\":\"$BID\"}"
ok "A17 10 s undo: rpc/acik_ofis_restore_save -> 200 {backup_id,best_score,best_stage,restored_from,revision}" "$(is '[[ $CODE == 200 && $(j "keys|join(\",\")") == backup_id,best_score,best_stage,restored_from,revision && $(j .restored_from) == $BID && $(j .revision) == $((L+1)) ]]')" "$CODE $BODY"
L=$(j .revision); up u1 "$(row "$U1" "$(save 250500 2)" $((L+1)))"
ok "A18 client writes its fresher snapshot with returned + 1 after undo" "$(is '[[ $CODE == 200 ]]')" "$CODE $BODY"
req DELETE "/rest/v1/acik_ofis_saves?user_id=eq.$U1" u1
ok "A19 DELETE own row -> 403 42501, row still there" "$(is '[[ $CODE == 403 && $(j .code) == 42501 ]]')" "$CODE $BODY"; seen 42501 "authenticated, no DELETE grant"
pull u1 "$U1"; ok "A20 row still present" "$(is '[[ $(j length) == 1 ]]')"
for c in best_score best_stage strict_revision; do
  req PATCH "/rest/v1/acik_ofis_saves?user_id=eq.$U1" u1 "{\"$c\":$([[ $c == strict_revision ]] && echo false || echo 99)}"
  ok "A21 client cannot write $c (PATCH -> 403 42501)" "$(is '[[ $CODE == 403 && $(j .code) == 42501 ]]')" "$CODE"
done
up u1 "{\"user_id\":\"$U1\",\"data\":$(save 251000 2),\"best_score\":1e30,\"revision\":$((L+2))}"
ok "A22 upsert carrying best_score -> 403 42501" "$(is '[[ $CODE == 403 && $(j .code) == 42501 ]]')" "$CODE"
pull u2 "$U1"; ok "A23 RLS: u2 reads u1's row -> 200 []" "$(is '[[ $CODE == 200 && $(j length) == 0 ]]')" "$CODE $BODY"
req PATCH "/rest/v1/acik_ofis_saves?user_id=eq.$U1" u2 "{\"data\":$(save 1 0)}" 'Prefer: return=representation'
ok "A24 RLS: u2 PATCH on u1's row changes nothing (200 [])" "$(is '[[ $CODE == 200 && $(j length) == 0 ]]')" "$CODE $BODY"
up u2 "$(row "$U1" "$(save 1 0)")"
ok "A25 RLS: u2 upsert with user_id = u1 -> 403 42501" "$(is '[[ $CODE == 403 && $(j .code) == 42501 ]]')" "$CODE $BODY"
pull u1 "$U1"; ok "A26 u1's row unchanged by u2 (250500)" "$(is '[[ $(j ".[0].data.totalEarned") == 250500 ]]')"
req GET '/rest/v1/acik_ofis_saves?select=user_id' anon
ok "A27 anon GET acik_ofis_saves -> 401 42501" "$(is '[[ $CODE == 401 && $(j .code) == 42501 ]]')" "$CODE $BODY"; seen 42501 "anon, no table grant"
req GET '/rest/v1/acik_ofis_save_backups?select=id' anon; ok "A28 anon GET acik_ofis_save_backups -> 401" "$(is '[[ $CODE == 401 ]]')" "$CODE"
req POST /rest/v1/rpc/acik_ofis_reset_save anon '{}'
ok "A29 anon rpc/acik_ofis_reset_save -> 401 (no EXECUTE for anon)" "$(is '[[ $CODE == 401 && $(j .code) == 42501 ]]')" "$CODE $BODY"; seen 42501 "anon, no EXECUTE on the RPC"
req POST /rest/v1/rpc/acik_ofis_reset_save u2 '{}'
ok "A30 reset without a row -> 200 {revision 0, backup_id null}" "$(is '[[ $CODE == 200 && $(j .revision) == 0 && $(j .backup_id) == null ]]')" "$CODE $BODY"
req POST /rest/v1/rpc/acik_ofis_restore_save u1 '{"p_backup_id":"00000000-0000-4000-8000-000000000000"}'
ok "A31 restore of a non-existent backup -> 404 PT404" "$(is '[[ $CODE == 404 && $(j .code) == PT404 ]]')" "$CODE"
# client contract: push reads the server revision back (return=representation + select=revision), L = returned
upr() { req POST '/rest/v1/acik_ofis_saves?on_conflict=user_id&select=revision' "$1" "$2" 'Prefer: resolution=merge-duplicates,return=representation'; }
up u2 "$(row "$U2" "$(save 1000 0)")"
upr u2 "$(row "$U2" "$(save 1200 0)" 0)"
ok "A32 lenient row, equal revision with return=representation: accepted, returns the server revision (old + 1)" "$(is '[[ $CODE == 200 && $(j ".[0].revision") == 1 ]]')" "$CODE $BODY"
L2=$(j ".[0].revision"); upr u2 "$(row "$U2" "$(save 1300 0)" $((L2+1)))"
ok "A33 next push L + 1 with the returned L: accepted, returns L + 1, row strict" "$(is '[[ $CODE == 200 && $(j ".[0].revision") == $((L2+1)) ]]')" "$CODE $BODY"

echo "== phase B: Kodhane over HTTP"
kup() { req POST '/rest/v1/kodhane_saves?on_conflict=user_id' "$1" "$2" 'Prefer: resolution=merge-duplicates,return=minimal'; }
kpull() { req GET "/rest/v1/kodhane_saves?select=data,revision,best_score,best_stage,strict_revision&user_id=eq.$2" "$1"; }
KS=$(db -Atc "select data from public.kodhane_saves limit 0" >/dev/null; echo ok)
# a plausible Kodhane save: the seed save of the SQL tests (kodhane_score_plausible accepts it)
KSAVE=$(db -Atc "select jsonb_build_object('v',3,'startedAt',(extract(epoch from now())*1000 - 3600000)::bigint,'lastSaved',(extract(epoch from now())*1000)::bigint,'totalEarned',1000,'money',1000,'stage',1,'playSec',3600,'simSec',3600)")
kup u1 "$(row "$U1" "$KSAVE" | sed 's/"save_version":2/"save_version":3/')"
ok "B1 old-client Kodhane upsert" "$(is '[[ $CODE == 201 ]]')" "$CODE $BODY"
kup u1 "$(row "$U1" '{"v":3,"totalEarned":0,"money":0}' | sed 's/"save_version":2/"save_version":3/')"
ok "B2 late empty Kodhane save -> 409 stale_write" "$(is '[[ $CODE == 409 && $(j .message) == stale_write ]]')" "$CODE"
kpull u1 "$U1"; KR=$(j '.[0].revision'); KB=$(j '.[0].best_score')
req POST /rest/v1/rpc/kodhane_reset_save u1 '{}'
ok "B3 rpc/kodhane_reset_save -> 200 {backup_id,best_score,best_stage,revision}" "$(is '[[ $CODE == 200 && $(j "keys|join(\",\")") == backup_id,best_score,best_stage,revision && $(j .revision) == $((KR+1)) ]]')" "$CODE $BODY"
KBID=$(j .backup_id)
req POST /rest/v1/rpc/kodhane_leaderboard anon '{"p_limit":50,"p_game":"kodhane"}'
ok "B4 anon rpc/kodhane_leaderboard(kodhane) after reset keeps the rank from best_score" "$(is '[[ $CODE == 200 && $(j "map(select(.nickname==\"Http Bir\"))[0].score") == $KB ]]')" "$CODE $BODY"
req POST /rest/v1/rpc/kodhane_leaderboard anon '{"p_limit":50,"p_game":"acik_ofis"}'
ok "B5 kodhane_leaderboard v6 (acik_ofis) still shows Açık Ofis best_score" "$(is '[[ $CODE == 200 && $(j "map(select(.nickname==\"Http Bir\"))[0].score") == 250500 ]]')" "$CODE $BODY"
req POST /rest/v1/rpc/kodhane_list_save_backups u1 '{}'; ok "B6 rpc/kodhane_list_save_backups" "$(is '[[ $CODE == 200 && $(j ".[0].id") == $KBID ]]')" "$CODE"
req POST /rest/v1/rpc/kodhane_restore_save u2 "{\"p_backup_id\":\"$KBID\"}"; ok "B7 cross-user Kodhane restore -> 404 PT404" "$(is '[[ $CODE == 404 && $(j .code) == PT404 ]]')" "$CODE"
req POST /rest/v1/rpc/kodhane_restore_save u1 "{\"p_backup_id\":\"$KBID\"}"; ok "B8 rpc/kodhane_restore_save -> 200" "$(is '[[ $CODE == 200 && $(j .restored_from) == $KBID ]]')" "$CODE $BODY"
req DELETE "/rest/v1/kodhane_saves?user_id=eq.$U1" u1; ok "B9 DELETE Kodhane row -> 403 42501" "$(is '[[ $CODE == 403 ]]')" "$CODE"
req PATCH "/rest/v1/kodhane_saves?user_id=eq.$U1" u1 '{"best_stage":99}'; ok "B10 client cannot write kodhane best_stage -> 403" "$(is '[[ $CODE == 403 ]]')" "$CODE"
kpull u2 "$U1"; ok "B11 RLS: u2 cannot read u1's Kodhane row" "$(is '[[ $CODE == 200 && $(j length) == 0 ]]')" "$CODE"
req GET '/rest/v1/kodhane_saves?select=user_id' anon; ok "B12 anon GET kodhane_saves -> 401" "$(is '[[ $CODE == 401 ]]')" "$CODE"
req POST /rest/v1/rpc/acik_ofis_list_save_backups u1 '{}'; ok "B13 Açık Ofis RPCs unaffected by the Kodhane file" "$(is '[[ $CODE == 200 && $(j length) -ge 2 ]]')" "$CODE"

echo "== phase C: rollback in reverse order (Açık Ofis, then Kodhane), with the guard flags"
out=$(PGOPTIONS='-c v22.acik_ofis_allow_backup_loss=on' db -1 -f "$RB_A" 2>&1); ok "C1 Açık Ofis rollback" "$(is '[[ "$out" != *ERROR* ]]')" "$(grep -m1 ERROR <<<"$out")"
out=$(PGOPTIONS='-c v22.kodhane_allow_backup_loss=on' db -1 -f "$RB_K" 2>&1); ok "C2 Kodhane rollback" "$(is '[[ "$out" != *ERROR* ]]')" "$(grep -m1 ERROR <<<"$out")"
db -c "notify pgrst, 'reload schema'" >/dev/null; sleep 2
ok "C3 kodhane_leaderboard back to v5 (no v6/shim comment)" "$(is '[[ $(db -Atc "select coalesce(obj_description('"'"'public.kodhane_leaderboard(integer,text)'"'"'::regprocedure, '"'"'pg_proc'"'"'), '"'"''"'"') !~ '"'"'v6|shim'"'"'") == t ]]')"
req POST /rest/v1/rpc/kodhane_leaderboard anon '{"p_limit":50,"p_game":"acik_ofis"}'
ok "C4 after rollback: anon rpc/kodhane_leaderboard answers again with v5 rules (current totalEarned)" "$(is '[[ $CODE == 200 && $(j "map(select(.nickname==\"Http Bir\"))[0].score") == 250500 ]]')" "$CODE $BODY"
req POST /rest/v1/rpc/acik_ofis_reset_save u1 '{}'
ok "C5 after rollback the v2.2 RPCs are gone (404)" "$(is '[[ $CODE == 404 ]]')" "$CODE"

echo "== status mapping observed"
printf '  %s\n' "${MAP[@]}" | sort -u | tee "$LOG.map"
echo "== cleanup (local game objects + test users)"
[[ "${KEEP:-}" == 1 ]] || reset_db
echo "$PASS passed, $FAIL failed, $((PASS+FAIL)) total   (details: $LOG)"
[[ $FAIL == 0 ]]
