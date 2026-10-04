#!/usr/bin/env bash
# OPTIONAL live check, SEPARATE from the B + progress log install (the install never depends on it; separate approval):
# a throw-away test account proves that a full account deletion removes its kodhane_progress_log rows.
# Runbook: docs/kodhane-v44b-install-runbook.md, "Ek: canlı silme testi". Steps, in this order, one run directory:
#   create   new auth user kodhane-deltest-YYYYMMDD-HHMMSS@example.invalid (direct SQL: no password, no identity,
#            no profile; cannot sign in, never on a leaderboard); id + e-mail + created_at recorded in $KODHANE_OUT/testuser.txt
#   write    two save writes as that player (role authenticated, committed); its progress-log rows must appear
#   delete   ops/kodhane_account_delete_preflight.sql -> ops/kodhane_account_delete.sql mode=full -> _verify.sql, then
#            0 rows of the uid in progress log / saves / backups / auth.users / audit log; other users' log rows intact
# Every step after create runs v44b_delete_test/guard.sql first: same id, test e-mail pattern AND = recorded e-mail,
# created_at = recorded instant, no sign-in / identity / profile / Açık Ofis data. Otherwise STOP, nothing done.
# Target as kodhane_v44b_install.sh (KODHANE_TARGET local | live, KODHANE_OUT required); live: every step needs
# KODHANE_LIVE_APPROVAL. Exit 0 = PASS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SB="$(cd "$HERE/.." && pwd)"; P="$HERE/v44b_delete_test"
STEP="${1:-}"; TARGET="${KODHANE_TARGET:-}"; OUT="${KODHANE_OUT:-}"
PEXEC="${KODHANE_PEXEC:-/workspace/kodhane-cloud/pexec.sh}"; PENV="${KODHANE_PENV:-/workspace/kodhane-cloud/penv_md5.py}"
ts() { date '+%Y-%m-%d %H:%M:%S.%3N TSİ'; }
mark() { echo "$(ts) deltest $STEP $*" >> "$OUT/times.txt"; }
die() { echo "STOP: $*"; mark "STOP: $*"; exit 1; }
[[ "$STEP" =~ ^(create|write|delete)$ && "$TARGET" =~ ^(local|live)$ && -n "$OUT" ]] || { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
umask 077; mkdir -p "$OUT/sql"; chmod 700 "$OUT"
if [[ "$TARGET" == local ]]; then : "${KODHANE_CT:?}"; : "${KODHANE_DB:?}"
else [[ -n "${PORTAINER_API_TOKEN:-}" ]] || die "PORTAINER_API_TOKEN is not exported"
     [[ -n "${KODHANE_LIVE_APPROVAL:-}" ]] || die "live deltest $STEP needs KODHANE_LIVE_APPROVAL (separate approval)"; mark "approval: $KODHANE_LIVE_APPROVAL"; fi
run_sql() {  # run_sql <name>
  local f="$OUT/sql/$1.sql" o="$OUT/$1.out" rc; mark "$1 start ($(md5sum < "$f" | cut -c1-32))"
  if [[ "$TARGET" == local ]]; then docker exec -i "$KODHANE_CT" psql -X -U supabase_admin -d "$KODHANE_DB" -f - < "$f" > "$o" 2>&1; rc=$?
  else python3 "$PENV" "$f" >> "$OUT/penv_md5.txt" 2>&1; tail -n1 "$OUT/penv_md5.txt" | grep -q ' MATCH' || die "penv_md5 mismatch"
       bash "$PEXEC" "$f" 2>&1 | tr -d '\r' > "$o"; rc=$(grep -oE '__EXIT=[0-9]+' "$o" | tail -n1 | cut -d= -f2); rc=${rc:-99}; fi
  mark "$1 end rc=$rc"; return "$rc"; }
HEAD='\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on
\pset footer off
\pset fieldsep |'
settings() {  # set_config lines for the recorded test user
  IFS='|' read -r T_UID T_EMAIL T_CREATED < "$OUT/testuser.txt" || die "no $OUT/testuser.txt (run create)"
  [[ "$T_UID" =~ ^[0-9a-f-]{36}$ && "$T_EMAIL" =~ ^kodhane-deltest-[0-9]{8}-[0-9]{6}@example\.invalid$ ]] || die "testuser.txt is not a test account"
  echo "select set_config('kd.t_uid', '$T_UID', false), set_config('kd.t_email', '$T_EMAIL', false), set_config('kd.t_created', '$T_CREATED', false);"
}
case "$STEP" in
  create)
    [[ -e "$OUT/testuser.txt" ]] && die "$OUT/testuser.txt exists: one test account per run directory"
    uid=$(python3 -c 'import uuid; print(uuid.uuid4())'); email="kodhane-deltest-$(date +%Y%m%d-%H%M%S)@example.invalid"
    { echo "$HEAD"; echo "begin;"; echo "select set_config('kd.t_uid', '$uid', true), set_config('kd.t_email', '$email', true);"
      cat "$P/create.sql"; echo "commit;"; } > "$OUT/sql/create.sql"
    run_sql create || { cat "$OUT/create.out"; die "create failed"; }
    line=$(grep -E '^TESTUSER\|' "$OUT/create.out" | tail -n1); [[ -n "$line" ]] || die "no TESTUSER line"
    echo "${line#TESTUSER|}" > "$OUT/testuser.txt"; echo "CREATE|PASS|$uid|${email%%@*}@…"
    ;;
  write)
    { echo "$HEAD"; settings; echo "begin;"; cat "$P/guard.sql" "$P/write.sql"; echo "commit;"; } > "$OUT/sql/write.sql"
    run_sql write; rc=$?; grep -E '^LOGROWS|STOP|ERROR' "$OUT/write.out"; [[ $rc == 0 ]] || die "write failed"
    echo "WRITE|PASS" ;;
  delete)
    settings > /dev/null; S=$(settings)
    { echo "$HEAD"; echo "$S"; echo "begin read only;"; cat "$P/guard.sql"
      echo "select 'OTHERS_BEFORE|' || count(*) || '|' || coalesce(max(id), 0) from public.kodhane_progress_log where user_id <> current_setting('kd.t_uid')::uuid;"
      echo "commit;"; echo "\\set uid '$T_UID'"; cat "$SB/ops/kodhane_account_delete_preflight.sql"; } > "$OUT/sql/del_preflight.sql"
    run_sql del_preflight || { tail -n 5 "$OUT/del_preflight.out"; die "guard / account-delete preflight failed"; }
    others=$(grep -oE '^OTHERS_BEFORE\|[0-9]+\|[0-9]+' "$OUT/del_preflight.out" | cut -d'|' -f2-)
    tok=$(grep -E '^(OK|BLOCKED|STOP):' "$OUT/del_preflight.out" | tail -n1); grep -q '^OK:' <<< "$tok" || die "account-delete preflight verdict: ${tok%%|*}"
    tok=${tok##*|}; [[ "$tok" =~ ^[0-9a-f]{12}$ ]] || die "no expect token"
    grep -E 'kodhane_progress_log' "$OUT/del_preflight.out" | sed 's/^/   preflight: /'
    { echo "$HEAD"; echo "$S"; echo "begin read only;"; cat "$P/guard.sql"; echo "commit;"
      echo "\\set mode full"; echo "\\set uid '$T_UID'"; echo "\\set confirm_uid '$T_UID'"
      echo "\\set approval_ref 'KD-DELTEST-$(date +%Y%m%d)'"; echo "\\set expect '$tok'"; cat "$SB/ops/kodhane_account_delete.sql"; } > "$OUT/sql/del_delete.sql"
    run_sql del_delete || { tail -n 5 "$OUT/del_delete.out"; die "account delete failed (one transaction: nothing deleted)"; }
    grep -E 'rows left|OK' "$OUT/del_delete.out" | tail -n 3 | sed 's/^/   delete: /'
    { echo "$HEAD"; echo "\\set mode full"; echo "\\set uid '$T_UID'"; cat "$SB/ops/kodhane_account_delete_verify.sql"; } > "$OUT/sql/del_verify.sql"
    run_sql del_verify || { tail -n 5 "$OUT/del_verify.out"; die "account delete verify failed"; }
    { echo "$HEAD"; echo "$S"; echo "select set_config('kd.t_others', '$others', false);"; echo "begin read only;"; cat "$P/check.sql"; echo "commit;"; } > "$OUT/sql/del_check.sql"
    run_sql del_check || die "check query failed"
    grep -E '^(LEFT|OTHERS)\|' "$OUT/del_check.out"
    left=$(grep -E '^LEFT\|' "$OUT/del_check.out" | awk -F'|' '{s += $3} END {print s + 0}')
    o=$(grep -E '^OTHERS\|' "$OUT/del_check.out" | cut -d'|' -f2); [[ "$left" == 0 && "$o" == "${others%%|*}" ]] || die "rows left $left, other users' log rows $o (before ${others%%|*})"
    echo "DELETE|PASS|0 rows of the test uid left; other users' log rows ${others%%|*} intact" ;;
esac
