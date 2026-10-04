#!/bin/sh
# Kodhane retention job (todo 26): LOCAL TEST / MANUAL TOOL. It is NOT what Dokploy runs: the live Dokploy compose task
# (Dokploy v0.30.8, service db) runs the one-line psql command in supabase/ops/kodhane_retention_dokploy_command.txt,
# because this file does not exist inside the container. Same steps, same order; runs INSIDE a db container.
#   1. public.kodhane_cleanup_save_backups()    Kodhane backups older than backup_retention_days (30), delete copies included
#   2. public.acik_ofis_cleanup_save_backups()  Açık Ofis backups, same rule (existing v2.2 functions, unchanged)
#   3. public.kodhane_cleanup_audit_log(batch)  auth.audit_log_entries older than 12 months, in batches (one transaction
#                                               each) until a batch is short or KD_AUDIT_MAX_BATCHES is reached
#   4. public.kodhane_cleanup_progress_log(365, batch)  progress log (kazanc gunlugu) older than 365 days, same batching.
#      Only if migration 20261003020000 is applied: otherwise "skipped" and exit 0 (the retention package is installed
#      before the progress log). After steps 1-3 on purpose: they are committed before it runs, so a failure here leaves them done.
#   5. kodhane_private.cleanup_deletion_log()   deletion log (silme listesi) rows older than 45 days. Only if migration
#      20261003040000 is applied (separate install step): otherwise "skipped". After step 4, same reason.
#   6. kodhane_loss.cleanup_loss_reports()      Kayıp bildir: closed reports (applied / rejected) 12 months after their last
#      status change (Aryen). Only if migration 20261003060000 (v4.5 P7, separate install + approval) is applied:
#      otherwise "skipped". LAST.
# Secrets: none in this file. Uses the container's own POSTGRES_PASSWORD only if it is set (never printed); local
# connections in the Supabase image are trust anyway. Never use set -x here.
# Env (optional): KD_DB (postgres), KD_PGUSER (postgres), KD_PGHOST (localhost), KD_AUDIT_BATCH (5000, 1..50000),
#                 KD_AUDIT_MAX_BATCHES (200).
# Exit: 0 OK (also when the batch cap is hit: the rest goes the next night), 2 bad parameter, 3 wrong target or
#       audit migration missing, other = psql error (nothing after the failing step runs). The progress log and deletion
#       log functions are not part of the exit-3 guard: without them steps 4 / 5 are skipped.
set -eu
if [ -n "${POSTGRES_PASSWORD:-}" ]; then PGPASSWORD="$POSTGRES_PASSWORD"; export PGPASSWORD; fi
DB=${KD_DB:-postgres}; B=${KD_AUDIT_BATCH:-5000}; MAXB=${KD_AUDIT_MAX_BATCHES:-200}
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
q() { psql -X -q -h "${KD_PGHOST:-localhost}" -U "${KD_PGUSER:-postgres}" -d "$DB" -v ON_ERROR_STOP=1 -Atc "$1"; }
case "$B" in ''|*[!0-9]*) echo "$(ts) kodhane retention: KD_AUDIT_BATCH must be a number 1..50000"; exit 2;; esac
case "$MAXB" in ''|*[!0-9]*) echo "$(ts) kodhane retention: KD_AUDIT_MAX_BATCHES must be a number"; exit 2;; esac
if [ "$B" -lt 1 ] || [ "$B" -gt 50000 ] || [ "$MAXB" -lt 1 ]; then echo "$(ts) kodhane retention: batch 1..50000, max batches >= 1"; exit 2; fi
g=$(q "select concat((to_regclass('public.kodhane_saves') is not null)::int, (to_regclass('public.acik_ofis_saves') is not null)::int,
                      (to_regprocedure('public.kodhane_cleanup_save_backups()') is not null)::int,
                      (to_regprocedure('public.acik_ofis_cleanup_save_backups()') is not null)::int,
                      (to_regprocedure('public.kodhane_cleanup_audit_log(integer)') is not null)::int)")
if [ "$g" != 11111 ]; then echo "$(ts) kodhane retention: wrong target or migration missing in database $DB ($g); nothing deleted"; exit 3; fi
kb=$(q "select public.kodhane_cleanup_save_backups()")
ab=$(q "select public.acik_ofis_cleanup_save_backups()")
total=0; i=0
while [ "$i" -lt "$MAXB" ]; do
  n=$(q "select public.kodhane_cleanup_audit_log($B)")
  total=$((total + n)); i=$((i + 1))
  if [ "$n" -lt "$B" ]; then break; fi
done
left=$(q "select count(*) from auth.audit_log_entries where created_at < now() - interval '12 months'")
echo "$(ts) kodhane retention OK: kodhane_save_backups $kb, acik_ofis_save_backups $ab, audit_log_entries $total ($i batch(es) of <= $B); audit rows older than 12 months left $left"
if [ "$left" -gt 0 ]; then echo "$(ts) kodhane retention: batch cap reached ($MAXB x $B); the rest is deleted on the next run"; fi
if [ "$(q "select (to_regprocedure('public.kodhane_cleanup_progress_log(integer,integer)') is not null)::int")" != 1 ]; then
  echo "$(ts) kodhane retention progress log skipped: migration 20261003020000 not applied in database $DB"
else
  ptotal=0; j=0
  while [ "$j" -lt "$MAXB" ]; do
    n=$(q "select public.kodhane_cleanup_progress_log(365, $B)")
    ptotal=$((ptotal + n)); j=$((j + 1))
    if [ "$n" -lt "$B" ]; then break; fi
  done
  pleft=$(q "select count(*) from public.kodhane_progress_log where created_at < now() - make_interval(days => 365)")
  echo "$(ts) kodhane retention progress log OK: kodhane_progress_log $ptotal ($j batch(es) of <= $B); rows older than 365 days left $pleft"
  if [ "$pleft" -gt 0 ]; then echo "$(ts) kodhane retention: progress log batch cap reached ($MAXB x $B); the rest is deleted on the next run"; fi
fi
if [ "$(q "select (to_regprocedure('kodhane_private.cleanup_deletion_log()') is not null)::int")" != 1 ]; then
  echo "$(ts) kodhane retention deletion log skipped: migration 20261003040000 not applied in database $DB"
else
  dl=$(q "select kodhane_private.cleanup_deletion_log()")
  echo "$(ts) kodhane retention deletion log OK: deletion_log $dl row(s) older than 45 days deleted"
fi
if [ "$(q "select (to_regprocedure('kodhane_loss.cleanup_loss_reports()') is not null)::int")" != 1 ]; then
  echo "$(ts) kodhane retention loss reports skipped: migration 20261003060000 not applied in database $DB"; exit 0
fi
lr=$(q "select kodhane_loss.cleanup_loss_reports()")
echo "$(ts) kodhane retention loss reports OK: loss_report $lr closed report(s) older than 12 months deleted"
