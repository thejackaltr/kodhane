#!/usr/bin/env bash
# Kodhane deletion log export (READ ONLY on the DB): kodhane_private.deletion_log -> one CSV file in $KODHANE_DL_DIR.
# Runbook: docs/kodhane-account-delete-runbook.md "Silme listesi". Run every 15 minutes (scheduler: separate approval)
# and ALWAYS right before a DB restore (docs/kodhane-v44b-install-runbook.md, restore step 0).
#   KODHANE_TARGET=local|live (see kodhane_deletion_log/lib.sh)  [KODHANE_DL_DIR=...]  bash supabase/ops/kodhane_deletion_log_export.sh
# Directory: KODHANE_DL_DIR (default /home/box/agent-data/backups/kodhane-deletion-log), mode 700, files mode 600.
# File: kodhane-deletion-log-YYYYMMDDTHHMMSSZ.csv (UTC) + .csv.md5; header user_id,scope,deleted_at_utc,approval_ref;
#   rows ordered by deleted_at. No e-mail, no nickname (the table has none).
#   - never overwrites a file (hard link of a temp file; an existing name = exit 4);
#   - same content as the newest file -> no new file ("unchanged");
#   - prunes files older than the retention (cfg_deletion_log_retention(), 45 days) by the time in the name; never the newest.
# Exit: 0 written or unchanged, 1 STOP (wrong target, list missing, DB error, bad output), 2 usage, 4 name exists.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/kodhane_deletion_log/lib.sh"
[[ "${1:-}" == "" ]] || { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
dl_target_init
DIR="${KODHANE_DL_DIR:-/home/box/agent-data/backups/kodhane-deletion-log}"
umask 077
mkdir -p "$DIR" && chmod 700 "$DIR" || dl_die "cannot create $DIR"
[[ "$(stat -c '%a %u' "$DIR")" == "700 $(id -u)" ]] || dl_die "$DIR must be mode 700 and owned by $(id -un)"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{ echo "$DL_PREFIX"; echo "begin read only;"; cat "$HERE/kodhane_deletion_log/export.sql"; echo "commit;"; echo "select 'DLX|END';"; } > "$W/export.sql"
dl_run_sql "$W/export.sql" "$W/export.out"; rc=$?
if [[ $rc != 0 ]] || ! grep -q '^DLX|END$' "$W/export.out"; then
  grep -oE 'DLX\|STOP\|.*|ERROR: .*' "$W/export.out" | head -n3
  dl_die "export query failed (rc $rc); no file written"
fi
n=$(grep -oE '^DLN\|[0-9]+$' "$W/export.out" | cut -d'|' -f2); days=$(grep -oE '^DLX\|db\|[^|]*\|retention_days\|[0-9]+$' "$W/export.out" | cut -d'|' -f5)
[[ -n "$n" && -n "$days" ]] || dl_die "export output incomplete"
{ echo "user_id,scope,deleted_at_utc,approval_ref"; grep -E '^DL\|' "$W/export.out" | cut -d'|' -f2- | tr '|' ','; } > "$W/new.csv"
bad=$(tail -n +2 "$W/new.csv" | grep -cvE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12},(account|kodhane),[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z,(self|info|purge):[^@,"\\[:cntrl:]]{1,200}$')
[[ $bad == 0 ]] || dl_die "$bad malformed row(s) in the export; no file written"
[[ $(( $(wc -l < "$W/new.csv") - 1 )) == "$n" ]] || dl_die "row count mismatch (DLN $n, rows $(( $(wc -l < "$W/new.csv") - 1 ))); no file written"
newest=$(ls -1 "$DIR"/kodhane-deletion-log-*.csv 2>/dev/null | sort | tail -n1)
if [[ -n "$newest" ]] && cmp -s "$newest" "$W/new.csv"; then
  echo "$(dl_ts) kodhane deletion log export: unchanged ($n row(s)), newest file $(basename "$newest"); no new file"
else
  name="kodhane-deletion-log-$(date -u +%Y%m%dT%H%M%SZ).csv"
  tmp=$(mktemp "$DIR/.tmp.XXXXXX"); cat "$W/new.csv" > "$tmp"; chmod 600 "$tmp"
  if ! ln "$tmp" "$DIR/$name" 2>/dev/null; then rm -f "$tmp"; echo "STOP: $DIR/$name exists (not overwritten)"; exit 4; fi
  rm -f "$tmp"
  ( cd "$DIR" && md5sum "$name" > "$name.md5.tmp" && chmod 600 "$name.md5.tmp" && mv "$name.md5.tmp" "$name.md5" ) || dl_die "cannot write $name.md5"
  echo "$(dl_ts) kodhane deletion log export: $n row(s) -> $DIR/$name ($(cut -c1-32 "$DIR/$name.md5"))"
fi
# prune: older than the retention by the UTC time in the name; the newest file always stays
cut=$(date -u -d "-$days days" +%Y%m%dT%H%M%SZ); newest=$(ls -1 "$DIR"/kodhane-deletion-log-*.csv 2>/dev/null | sort | tail -n1); pruned=0
for f in "$DIR"/kodhane-deletion-log-*.csv; do
  [[ -e "$f" && "$f" != "$newest" ]] || continue
  t=$(basename "$f" .csv); t=${t#kodhane-deletion-log-}
  if [[ "$t" < "$cut" ]]; then rm -f "$f" "$f.md5"; pruned=$((pruned + 1)); fi
done
[[ $pruned == 0 ]] || echo "$(dl_ts) kodhane deletion log export: pruned $pruned file(s) older than $days days"
exit 0
