#!/usr/bin/env bash
# Kodhane deletion log: after a DB restore, delete the listed uids again (reapply), or check that nothing listed is back
# (verify). Runbook: docs/kodhane-account-delete-runbook.md "Silme listesi", docs/kodhane-v44b-install-runbook.md restore.
#   KODHANE_TARGET=local|live KODHANE_OUT=<run dir> bash supabase/ops/kodhane_deletion_log_reapply.sh <reapply|verify|dryrun> [file.csv ...]
# Files: the given export files, else every kodhane-deletion-log-*.csv in KODHANE_DL_DIR (default
#   /home/box/agent-data/backups/kodhane-deletion-log). Every file must match its .md5, the name pattern, the header and
#   the row format; ONE bad file = STOP, nothing runs (remove or repair it deliberately, then run again).
# ONE transaction for all entries (union of the files and the DB list): list rows written first (ON CONFLICT DO NOTHING),
#   then per uid + scope the delete of ops/kodhane_account_delete.sql (its DO block verbatim; scope account = mode full,
#   kodhane = mode kodhane_only, only Kodhane rows older than the deletion), then a check that nothing is left.
#   Idempotent: a second run changes nothing. A row outside Kodhane / Açık Ofis (block) or an orphan stops everything.
#   dryrun = the same transaction ending in ROLLBACK; verify = the checks only, ROLLBACK.
# Live reapply needs KODHANE_LIVE_APPROVAL="<who, when>".
# Exit: 0 PASS; 3 reapply committed but MIXED entries (Aryen decides); 1 STOP / FAIL (nothing changed unless it says
#       committed); 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/kodhane_deletion_log/lib.sh"
MODE="${1:-}"; shift || true
[[ "$MODE" == reapply || "$MODE" == verify || "$MODE" == dryrun ]] || { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
dl_target_init
OUT="${KODHANE_OUT:-}"; [[ -n "$OUT" ]] || dl_die "KODHANE_OUT (run directory) is required"
umask 077; mkdir -p "$OUT" && chmod 700 "$OUT" || dl_die "cannot create $OUT"
if [[ "$MODE" == reapply && "$DL_TARGET" == live ]]; then
  [[ -n "${KODHANE_LIVE_APPROVAL:-}" ]] || dl_die "live reapply needs KODHANE_LIVE_APPROVAL (who approved, when)"
  echo "$(dl_ts) reapply approval: $KODHANE_LIVE_APPROVAL" >> "$OUT/times.txt"
fi
if [[ $# -gt 0 ]]; then FILES=("$@")
else
  DIR="${KODHANE_DL_DIR:-/home/box/agent-data/backups/kodhane-deletion-log}"
  mapfile -t FILES < <(ls -1 "$DIR"/kodhane-deletion-log-*.csv 2>/dev/null | sort)
fi
SQL="$OUT/deletion_log_$MODE.sql"; RES="$OUT/deletion_log_$MODE.out"
python3 "$HERE/kodhane_deletion_log/build_reapply.py" "$MODE" "$HERE/kodhane_account_delete.sql" "$HERE/kodhane_deletion_log/reapply.sql" "$SQL" "${FILES[@]}" > "$OUT/deletion_log_${MODE}_files.txt" 2>&1
rc=$?; cat "$OUT/deletion_log_${MODE}_files.txt"
[[ $rc == 0 ]] || dl_die "export file check failed; nothing run"
echo "$(dl_ts) deletion log $MODE start ($(md5sum < "$SQL" | cut -c1-32), ${#FILES[@]} file(s))" >> "$OUT/times.txt"
dl_run_sql "$SQL" "$RES"; rc=$?
echo "$(dl_ts) deletion log $MODE end rc=$rc" >> "$OUT/times.txt"
grep -E '^(ENTRY|REAPPLY|VERIFY|DRYRUN)\|' "$RES"; grep -oE 'ERROR: .*' "$RES" | head -n3
U=$(echo "$MODE" | tr a-z A-Z); [[ $MODE == dryrun ]] && U=REAPPLY
sum=$(grep -E "^$U\|file_rows\|" "$RES" | tail -n1); left=$(grep -E "^$U\|left\|" "$RES" | tail -n1)
case "$MODE" in
  reapply)
    [[ $rc == 0 ]] && grep -q '^REAPPLY|PASS|committed' "$RES" || dl_die "reapply did not commit (rc $rc; one transaction: nothing changed). See $RES"
    if [[ "$left" != "REAPPLY|left|0|mixed|0" ]]; then echo "REAPPLY|COMMITTED|MIXED entries left for Aryen (see ENTRY lines)"; exit 3; fi
    echo "REAPPLY|PASS" ;;
  dryrun)
    [[ $rc == 0 ]] && grep -q '^DRYRUN|END|rolled back' "$RES" || dl_die "dry run failed (rc $rc). See $RES"
    echo "DRYRUN|PASS|rolled back" ;;
  verify)
    [[ $rc == 0 && -n "$sum" ]] || dl_die "verify query failed (rc $rc). See $RES"
    miss=$(echo "$sum" | awk -F'|' '{for (i = 1; i < NF; i++) if ($i == "list_rows_missing_before") print $(i+1)}')
    if [[ "$left" == "VERIFY|left|0|mixed|0" && "$miss" == 0 ]]; then echo "VERIFY|PASS|0 left"
    else echo "VERIFY|FAIL|$left|list_rows_missing $miss"; exit 1; fi ;;
esac
exit 0
