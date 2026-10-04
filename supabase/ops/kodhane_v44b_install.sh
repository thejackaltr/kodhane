#!/usr/bin/env bash
# Kodhane v4.4: live install package for package B (20260929204000) + progress log (20261003020000).
# Runbook: docs/kodhane-v44b-install-runbook.md. One run directory ($KODHANE_OUT) per install; steps in this order:
#   build      check input md5s (v44b_install/inputs.md5), generate the SQL files into $KODHANE_OUT/sql (+ sql.md5)
#   backup     full pg_dump -Fc -> $KODHANE_BACKUP_DIR/kodhane-shared-YYYYMMDD-HHMM.dump (600) + .md5, pg_restore -l check
#   preflight  READ ONLY: A md5 969e1dc2..., B and progress log absent, save-format counts; STOP on anything unexpected
#   dryrun     B + progress log in one transaction, checks, object md5s, ROLLBACK
#   install    the same transaction with COMMIT (needs PASS of backup, preflight and dryrun in this run directory)
#   verify     synthetic player in one transaction, ROLLBACK; object md5s must equal the dry-run
#   rollback   progress log rollback, then B rollback (= back to A 969e1dc2...) in one transaction
#   delete-path-check  READ ONLY, after the install: catalog proof that account deletion removes progress-log rows
#              (FK ON DELETE CASCADE + the ops file ops/kodhane_account_delete.sql, md5-pinned in inputs.md5)
#   restore <dump>   LAST RESORT: full in-place restore of a backup of this run (one transaction; every write since the
#              backup is lost). Needs KODHANE_RESTORE_CONFIRM=<dump file name>; live also KODHANE_LIVE_APPROVAL.
#              Deletion log (migration 20261003040000, separate install): BEFORE the restore the last list is exported from
#              the current DB (kodhane_deletion_log_export.sh; not installed there = nothing to export; export failure =
#              STOP unless KODHANE_RESTORE_WITHOUT_DELETION_LOG_EXPORT=on); AFTER it kodhane_deletion_log_reapply.sh
#              reapply + verify with every export file in KODHANE_DL_DIR (live default
#              /home/box/agent-data/backups/kodhane-deletion-log, local default $KODHANE_OUT/deletion-log).
# Target (no default):
#   KODHANE_TARGET=local  KODHANE_CT=<docker container> KODHANE_DB=<database>   rehearsal (docker exec psql -U supabase_admin)
#   KODHANE_TARGET=live   PORTAINER_API_TOKEN exported (never printed)          Portainer exec, as for package A:
#                         KODHANE_PEXEC (default /workspace/kodhane-cloud/pexec.sh), KODHANE_PENV (penv_md5.py),
#                         KODHANE_PDUMP (pdump_env.py); install / rollback also need KODHANE_LIVE_APPROVAL="<who, when>"
#                         KODHANE_PORTAINER_URL, KODHANE_DB_CONTAINER (no default; local sb_env.sh, see sb_env.example.sh)
# Other: KODHANE_OUT (required), KODHANE_BACKUP_DIR (default /home/box/agent-data/backups),
#        KODHANE_ALLOW_PROGRESS_LOG_LOSS=on (rollback only: drop a non-empty progress log).
# Exit 0 = step PASS; 1 = STOP / FAIL (the step output says why); 2 = usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$(cd "$HERE/.." && pwd)"
P="$HERE/v44b_install"
MIG_B=migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql
MIG_PL=migrations/20261003020000_v4_4_kodhane_progress_log.sql
RB_B=rollback/20260929204000_v4_4b_kodhane_stage_ids_version_guard.rollback.sql
RB_PL=rollback/20261003020000_v4_4_kodhane_progress_log.rollback.sql
STEP="${1:-}"; TARGET="${KODHANE_TARGET:-}"; OUT="${KODHANE_OUT:-}"
BACKUP_DIR="${KODHANE_BACKUP_DIR:-/home/box/agent-data/backups}"
PEXEC="${KODHANE_PEXEC:-/workspace/kodhane-cloud/pexec.sh}"
PENV="${KODHANE_PENV:-/workspace/kodhane-cloud/penv_md5.py}"
PDUMP="${KODHANE_PDUMP:-/workspace/kodhane-cloud/pdump_env.py}"

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "STOP: $*"; echo "$(ts) $STEP STOP: $*" >> "$OUT/times.txt" 2>/dev/null; exit 1; }
ts() { date '+%Y-%m-%d %H:%M:%S.%3N TSİ'; }
mark() { echo "$(ts) $STEP $*" >> "$OUT/times.txt"; }
[[ -n "$STEP" ]] || usage
[[ "$TARGET" == local || "$TARGET" == live ]] || { echo "KODHANE_TARGET must be local or live"; usage; }
[[ -n "$OUT" ]] || { echo "KODHANE_OUT (run directory) is required"; usage; }
umask 077; mkdir -p "$OUT/sql"; chmod 700 "$OUT"
if [[ "$TARGET" == local ]]; then
  : "${KODHANE_CT:?KODHANE_CT required for local}"; : "${KODHANE_DB:?KODHANE_DB required for local}"
else
  [[ -n "${PORTAINER_API_TOKEN:-}" ]] || die "PORTAINER_API_TOKEN is not exported"
  [[ -n "${KODHANE_PORTAINER_URL:-}" ]] || die "KODHANE_PORTAINER_URL is not set (Portainer Docker API base URL; no default, see supabase/sb_env.example.sh)"
  [[ -n "${KODHANE_DB_CONTAINER:-}" ]] || die "KODHANE_DB_CONTAINER is not set (live DB container name; no default, see supabase/sb_env.example.sh)"
  export KODHANE_PORTAINER_URL KODHANE_DB_CONTAINER
  for f in "$PEXEC" "$PENV" "$PDUMP"; do [[ -r "$f" ]] || die "missing $f"; done
fi
need_approval() {
  [[ "$TARGET" == local ]] && return 0
  [[ -n "${KODHANE_LIVE_APPROVAL:-}" ]] || die "live $STEP needs KODHANE_LIVE_APPROVAL (who approved, when)"
  mark "approval: $KODHANE_LIVE_APPROVAL"
}
need_pass() {  # need_pass <file> <regex>
  [[ -f "$OUT/$1" ]] && grep -Eq "$2" "$OUT/$1" || die "$1 has no $2 in $OUT (run that step first)"
}

# run_sql <name>: $OUT/sql/<name>.sql -> $OUT/<name>.out; returns psql's exit code
run_sql() {
  local f="$OUT/sql/$1.sql" o="$OUT/$1.out" rc
  [[ -r "$f" ]] || die "missing $f (run build)"
  mark "$1 start ($(md5sum < "$f" | cut -c1-32))"
  if [[ "$TARGET" == local ]]; then
    docker exec -i "$KODHANE_CT" psql -X -U supabase_admin -d "$KODHANE_DB" -f - < "$f" > "$o" 2>&1; rc=$?
  else
    python3 "$PENV" "$f" >> "$OUT/penv_md5.txt" 2>&1
    tail -n1 "$OUT/penv_md5.txt" | grep -q ' MATCH' || die "penv_md5: file did not arrive intact ($(tail -n1 "$OUT/penv_md5.txt"))"
    bash "$PEXEC" "$f" 2>&1 | tr -d '\r' > "$o"
    rc=$(grep -oE '__EXIT=[0-9]+' "$o" | tail -n1 | cut -d= -f2); rc=${rc:-99}
  fi
  mark "$1 end rc=$rc"
  return "$rc"
}

strip_tx() {  # print a migration / rollback file without its own top-level "begin;" and "commit;" lines (exactly one each)
  python3 - "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split('\n')
b = [i for i, l in enumerate(lines) if l == 'begin;']; c = [i for i, l in enumerate(lines) if l == 'commit;']
assert len(b) == 1 and len(c) == 1 and b[0] < c[0], 'expected exactly one top-level begin; / commit; in ' + sys.argv[1]
print('\n'.join(l if i not in (b[0], c[0]) else '-- (' + l + ' removed: runs inside the install transaction)' for i, l in enumerate(lines)))
PY
}

PREFIX='\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on
\pset footer off'

build() {
  ( cd "$SB" && md5sum --quiet -c "$P/inputs.md5" ) || die "input files differ from v44b_install/inputs.md5 (reviewed versions)"
  local S="$OUT/sql"
  { echo "-- generated by supabase/ops/kodhane_v44b_install.sh build: preflight (READ ONLY)"; echo "$PREFIX"
    echo "begin read only;"; cat "$P/preflight.sql" "$P/lb_snapshot.sql" "$P/objects.sql"
    echo "select 'PREFLIGHT|PASS';"; echo "commit;"; } > "$S/preflight.sql"
  { cat "$P/tx_start.sql" "$P/assert_a.sql" "$P/lb_before.sql"
    echo "-- ======================================== $MIG_B"; cat "$SB/$MIG_B"
    echo "-- ======================================== $MIG_PL"; strip_tx "$SB/$MIG_PL" || exit 1
    echo "-- ======================================== checks"; echo "notify pgrst, 'reload schema';"
    cat "$P/lb_check.sql" "$P/postcheck.sql" "$P/lb_snapshot.sql" "$P/objects.sql"; } > "$S/tx_body.part" || die "build failed"
  { echo "-- generated by supabase/ops/kodhane_v44b_install.sh build: DRY RUN (ends with ROLLBACK)"; echo "$PREFIX"
    echo "begin;"; cat "$S/tx_body.part"; echo "select 'DRYRUN|PASS|rolled back';"; echo "rollback;"; } > "$S/dryrun.sql"
  { echo "-- generated by supabase/ops/kodhane_v44b_install.sh build: INSTALL (B, then progress log; one transaction)"; echo "$PREFIX"
    echo "begin;"; cat "$S/tx_body.part"; echo "commit;"; echo "select 'INSTALL|PASS|committed';"; } > "$S/install.sql"
  for loss in no yes; do
    { echo "-- generated by supabase/ops/kodhane_v44b_install.sh build: ROLLBACK progress log, then B (back to A); one transaction"
      echo "$PREFIX"; echo "begin;"; cat "$P/tx_start.sql"
      [[ $loss == yes ]] && echo "set local kodhane.progress_log_allow_loss = on;   -- KODHANE_ALLOW_PROGRESS_LOG_LOSS=on: the log's rows are dropped"
      echo "-- ======================================== $RB_PL"; strip_tx "$SB/$RB_PL" || exit 1
      echo "-- ======================================== $RB_B"; cat "$SB/$RB_B"
      echo "-- ======================================== checks"; echo "notify pgrst, 'reload schema';"
      cat "$P/rollback_check.sql" "$P/lb_snapshot.sql" "$P/objects.sql"; echo "commit;"; echo "select 'ROLLBACK|PASS|committed';"
    } > "$S/rollback$([[ $loss == yes ]] && echo _allow_loss).sql" || die "build failed"
  done
  rm -f "$S/tx_body.part"
  { echo "-- generated by supabase/ops/kodhane_v44b_install.sh build: delete-path check (READ ONLY)"; echo "$PREFIX"
    echo "begin read only;"; cat "$P/delete_path_check.sql"; echo "commit;"; } > "$S/delete_path_check.sql"
  ( cd "$S" && md5sum preflight.sql dryrun.sql install.sql rollback.sql rollback_allow_loss.sql delete_path_check.sql > ../sql.md5 )
  { echo "BUILD|PASS"; ( cd "$SB" && md5sum $MIG_B $MIG_PL $RB_B $RB_PL ); cat "$OUT/sql.md5"; } | tee "$OUT/build.out"
}

backup() {
  mkdir -p "$BACKUP_DIR"
  local f="$BACKUP_DIR/kodhane-shared-$(date +%Y%m%d-%H%M).dump"
  [[ -e "$f" ]] && die "$f exists (wait a minute or remove a failed attempt)"
  mark "pg_dump start -> $f"
  if [[ "$TARGET" == local ]]; then
    docker exec "$KODHANE_CT" pg_dump -U supabase_admin -d "$KODHANE_DB" -Fc > "$f" || die "pg_dump failed"
  else
    python3 "$PDUMP" "$f" '["pg_dump","-h","localhost","-U","supabase_admin","-d","postgres","-Fc"]' | tee "$OUT/pdump.txt"
    grep -q ' exit 0 ' "$OUT/pdump.txt" || die "pg_dump via Portainer did not exit 0"
  fi
  chmod 600 "$f"; mark "pg_dump end"
  [[ -s "$f" ]] || die "dump is empty"
  ( cd "$BACKUP_DIR" && md5sum "$(basename "$f")" > "$(basename "$f").md5" && chmod 600 "$(basename "$f").md5" )
  pg_restore -l "$f" > "$OUT/backup_toc.txt" 2>&1 || die "pg_restore -l cannot read the dump"
  local toc_t toc_d db_t
  toc_t=$(grep -cE '^[0-9]+; [0-9]+ [0-9]+ TABLE [^D]' "$OUT/backup_toc.txt")
  toc_d=$(grep -cE '^[0-9]+; [0-9]+ [0-9]+ TABLE DATA ' "$OUT/backup_toc.txt")
  # tables the dump must contain: ordinary / partitioned tables outside the catalogs that are not extension members
  cat > "$OUT/sql/backup_count.sql" <<SQL
$PREFIX
select 'DBTABLES|' || count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r', 'p') and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname !~ '^pg_(toast|temp)'
   and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e');
SQL
  run_sql backup_count || die "table count query failed"
  db_t=$(grep -oE 'DBTABLES\|[0-9]+' "$OUT/backup_count.out" | cut -d'|' -f2)
  grep -qE ' TABLE DATA public kodhane_saves ' "$OUT/backup_toc.txt" || die "dump has no data of public.kodhane_saves"
  { echo "file $f"; echo "bytes $(stat -c %s "$f") mode $(stat -c %a "$f")"; cat "$f.md5"
    echo "toc TABLE $toc_t, TABLE DATA $toc_d; database tables $db_t"; } > "$OUT/backup.out"
  [[ "$toc_t" == "$db_t" ]] || { cat "$OUT/backup.out"; die "table count of the dump ($toc_t) != database ($db_t)"; }
  echo "BACKUP|PASS" >> "$OUT/backup.out"; cat "$OUT/backup.out"
}

objects() { grep '^OBJ|' "$OUT/$1.out" > "$OUT/objects_$1.txt"; }

case "$STEP" in
  build) build ;;
  backup) backup ;;
  preflight)
    run_sql preflight; rc=$?; grep -E '^(INFO|LB)\|' "$OUT/preflight.out"; grep -E 'STOP|ERROR' "$OUT/preflight.out"
    [[ $rc == 0 ]] && grep -q '^PREFLIGHT|PASS' "$OUT/preflight.out" || die "preflight did not pass (see $OUT/preflight.out)"
    objects preflight; echo "PREFLIGHT|PASS" ;;
  dryrun)
    need_pass preflight.out '^PREFLIGHT\|PASS'
    run_sql dryrun; rc=$?; grep -E '^(CHECK|LB)\|' "$OUT/dryrun.out"; grep -E 'STOP|ERROR' "$OUT/dryrun.out"
    [[ $rc == 0 ]] && grep -q '^DRYRUN|PASS' "$OUT/dryrun.out" || die "dry run did not pass (see $OUT/dryrun.out)"
    objects dryrun
    diff "$OUT/objects_preflight.txt" "$OUT/objects_dryrun.txt" > "$OUT/objects_new_or_changed.diff"
    echo "objects new or changed by B + progress log: $(grep -c '^>' "$OUT/objects_new_or_changed.diff") (+), removed / replaced: $(grep -c '^<' "$OUT/objects_new_or_changed.diff") (-) -> objects_new_or_changed.diff"
    grep '^> OBJ|FN|' "$OUT/objects_new_or_changed.diff" | cut -d'|' -f3,4
    echo "DRYRUN|PASS" ;;
  install)
    need_approval
    need_pass backup.out '^BACKUP\|PASS'; need_pass preflight.out '^PREFLIGHT\|PASS'; need_pass dryrun.out '^DRYRUN\|PASS'
    ( cd "$OUT/sql" && md5sum --quiet -c ../sql.md5 ) || die "generated SQL changed since build"
    run_sql install; rc=$?; grep -E '^(CHECK|LB)\|' "$OUT/install.out"; grep -E 'STOP|ERROR' "$OUT/install.out"
    [[ $rc == 0 ]] && grep -q '^INSTALL|PASS' "$OUT/install.out" || die "install did not commit (see $OUT/install.out; nothing changed if the error came before COMMIT)"
    objects install
    cmp -s "$OUT/objects_dryrun.txt" "$OUT/objects_install.txt" && echo "objects install = dry-run: MATCH" || die "objects after install differ from the dry run (objects_*.txt)"
    echo "INSTALL|PASS" ;;
  verify)
    need_pass install.out '^INSTALL\|PASS'
    lb=$(grep -E '^LB\|kodhane\|' "$OUT/install.out" | tail -n1 | cut -d'|' -f4); [[ -n "$lb" ]] || die "no LB|kodhane line in install.out"
    { echo "-- generated by supabase/ops/kodhane_v44b_install.sh verify (ends with ROLLBACK)"; echo "$PREFIX"; echo "begin;"
      echo "select set_config('kd.lb_install', '$lb', true);"
      cat "$P/verify.sql" "$P/lb_snapshot.sql" "$P/objects.sql"; echo "rollback;"; } > "$OUT/sql/verify.sql"
    run_sql verify; rc=$?; grep -E '^(CHECK|VERIFY|LB)\|' "$OUT/verify.out"; grep -E 'STOP|ERROR' "$OUT/verify.out"
    objects verify
    cmp -s "$OUT/objects_dryrun.txt" "$OUT/objects_verify.txt" && echo "objects verify = dry-run: MATCH" || die "objects differ from the dry run"
    [[ $rc == 0 ]] && grep -q '^VERIFY|PASS' "$OUT/verify.out" || die "verify did not pass (see $OUT/verify.out)"
    echo "VERIFY|PASS" ;;
  rollback)
    need_approval
    f=rollback; [[ "${KODHANE_ALLOW_PROGRESS_LOG_LOSS:-}" == on ]] && f=rollback_allow_loss
    ( cd "$OUT/sql" && md5sum --quiet -c ../sql.md5 ) || die "generated SQL changed since build"
    run_sql $f; rc=$?; grep -E '^(CHECK|LB)\|' "$OUT/$f.out"; grep -E 'STOP|ERROR' "$OUT/$f.out"
    [[ $rc == 0 ]] && grep -q '^ROLLBACK|PASS' "$OUT/$f.out" || die "rollback did not commit (see $OUT/$f.out; nothing changed if the error came before COMMIT)"
    echo "ROLLBACK|PASS" ;;
  delete-path-check)
    run_sql delete_path_check; rc=$?; grep -E '^(INFO|CHECK|DELPATH_SQL)\|' "$OUT/delete_path_check.out"; grep -E 'ERROR' "$OUT/delete_path_check.out"
    ok=1
    ( cd "$SB" && grep -E ' ops/kodhane_account_delete(_verify)?\.sql$' "$P/inputs.md5" | md5sum --quiet -c - ) \
      && echo "CHECK|delpath_file_md5|t|ops/kodhane_account_delete.sql + _verify.sql = reviewed md5 ($(cd "$SB" && md5sum ops/kodhane_account_delete.sql | cut -c1-32))" \
      || { echo "CHECK|delpath_file_md5|f|ops/kodhane_account_delete*.sql differ from inputs.md5"; ok=0; }
    if grep -q "execute 'delete from public.kodhane_progress_log where user_id = \$1' using v_uid;" "$SB/ops/kodhane_account_delete.sql" \
       && grep -q 'kodhane_progress_log' "$SB/ops/kodhane_account_delete_verify.sql"; then
      echo "CHECK|delpath_file_stmt|t|kodhane_account_delete.sql deletes the uid's log rows in both modes (step K3b, before the mode branch); verify counts them"
    else echo "CHECK|delpath_file_stmt|f|progress-log DELETE missing in ops/kodhane_account_delete.sql"; ok=0; fi
    [[ $rc == 0 && $ok == 1 ]] && grep -q '^DELPATH_SQL|PASS' "$OUT/delete_path_check.out" || { echo "DELPATH|FAIL"; exit 1; }
    echo "DELPATH|PASS" ;;
  restore)
    need_approval
    d="${2:-}"; [[ -r "$d" && -r "$d.md5" ]] || die "restore needs a readable dump and its .md5: $d"
    [[ "${KODHANE_RESTORE_CONFIRM:-}" == "$(basename "$d")" ]] || die "set KODHANE_RESTORE_CONFIRM=$(basename "$d") to confirm the full restore"
    ( cd "$(dirname "$d")" && md5sum --quiet -c "$(basename "$d").md5" ) || die "dump md5 does not match $d.md5"
    # step 0: the last deletion log from the CURRENT DB (deletions after the backup must be done again after the restore)
    if [[ "$TARGET" == local ]]; then export KODHANE_DL_DIR="${KODHANE_DL_DIR:-$OUT/deletion-log}"
    else export KODHANE_DL_DIR="${KODHANE_DL_DIR:-/home/box/agent-data/backups/kodhane-deletion-log}"; fi
    mark "deletion log export start -> $KODHANE_DL_DIR"
    bash "$HERE/kodhane_deletion_log_export.sh" > "$OUT/deletion_log_export_before_restore.out" 2>&1; xrc=$?
    mark "deletion log export end rc=$xrc"; cat "$OUT/deletion_log_export_before_restore.out"
    if [[ $xrc != 0 ]]; then
      if grep -q 'DLX|STOP|kodhane_private.deletion_log does not exist' "$OUT/deletion_log_export_before_restore.out"; then
        echo "deletion log: not installed in the current DB (migration 20261003040000), nothing to export"
      elif [[ "${KODHANE_RESTORE_WITHOUT_DELETION_LOG_EXPORT:-}" == on ]]; then
        echo "WARNING: deletion log export from the current DB failed; KODHANE_RESTORE_WITHOUT_DELETION_LOG_EXPORT=on: going on with the existing export files only"
        mark "deletion log export failed, override KODHANE_RESTORE_WITHOUT_DELETION_LOG_EXPORT=on"
      else die "deletion log export from the current DB failed (see $OUT/deletion_log_export_before_restore.out). Fix it, or (DB unreadable) set KODHANE_RESTORE_WITHOUT_DELETION_LOG_EXPORT=on"; fi
    fi
    pg_restore --clean --if-exists -f "$OUT/sql/full_restore.body" "$d" || die "pg_restore cannot convert the dump"
    { echo "-- generated by supabase/ops/kodhane_v44b_install.sh restore $(basename "$d") (LAST RESORT, one transaction)"
      echo '\set ON_ERROR_STOP on'; echo "begin;"; cat "$P/full_restore_prelude.sql" "$OUT/sql/full_restore.body"
      echo "commit;"; echo "select 'RESTORE|PASS|committed';"; } > "$OUT/sql/full_restore.sql"; rm -f "$OUT/sql/full_restore.body"
    mark "full_restore start ($(md5sum < "$OUT/sql/full_restore.sql" | cut -c1-32), $(stat -c %s "$OUT/sql/full_restore.sql") bytes)"
    if [[ "$TARGET" == local ]]; then
      docker exec -i "$KODHANE_CT" psql -X -q -U supabase_admin -d "$KODHANE_DB" -f - < "$OUT/sql/full_restore.sql" > "$OUT/full_restore.out" 2>&1; rc=$?
    else
      # too large for pexec (environment variable): upload as a file (Portainer archive API), run psql -f, delete it.
      # NOT rehearsed against Portainer (the local rehearsal runs the same SQL through docker exec).
      python3 - "$OUT/sql/full_restore.sql" > "$OUT/full_restore.out" 2>&1 <<'PY2'
import io, json, os, struct, sys, tarfile, urllib.request
src = sys.argv[1]; tok = os.environ['PORTAINER_API_TOKEN']; CT = os.environ['KODHANE_DB_CONTAINER']
API = os.environ['KODHANE_PORTAINER_URL'].rstrip('/')
H = {'X-API-Key': tok, 'User-Agent': 'Mozilla/5.0'}
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w') as t:
    ti = t.gettarinfo(src, arcname='kodhane-full-restore.sql'); ti.uid = ti.gid = 0; ti.mode = 0o644
    with open(src, 'rb') as f: t.addfile(ti, f)
urllib.request.urlopen(urllib.request.Request(API + '/containers/%s/archive?path=/tmp' % CT, data=buf.getvalue(),
    headers=dict(H, **{'Content-Type': 'application/x-tar'}), method='PUT'), timeout=120).read()
def run(cmd):
    ex = json.load(urllib.request.urlopen(urllib.request.Request(API + '/containers/%s/exec' % CT, data=json.dumps({"AttachStdout": True,
        "AttachStderr": True, "Tty": False, "User": "postgres", "Cmd": cmd}).encode(), headers=dict(H, **{'Content-Type': 'application/json'}), method='POST'), timeout=60))
    raw = urllib.request.urlopen(urllib.request.Request(API + '/exec/%s/start' % ex['Id'], data=b'{"Detach":false,"Tty":false}',
        headers=dict(H, **{'Content-Type': 'application/json'}), method='POST'), timeout=1800).read()
    out, i = bytearray(), 0
    while i + 8 <= len(raw):
        n = struct.unpack('>I', raw[i+4:i+8])[0]; out.extend(raw[i+8:i+8+n]); i += 8 + n
    code = json.load(urllib.request.urlopen(urllib.request.Request(API + '/exec/%s/json' % ex['Id'], headers=H), timeout=60)).get('ExitCode')
    return out.decode(errors='replace'), code
o, c = run(["sh", "-c", "md5sum /tmp/kodhane-full-restore.sql"]); print(o.strip())
o, c = run(["psql", "-X", "-q", "-h", "localhost", "-U", "supabase_admin", "-d", "postgres", "-f", "/tmp/kodhane-full-restore.sql"]); print(o)
run(["rm", "-f", "/tmp/kodhane-full-restore.sql"]); print('__EXIT=%s' % c)
PY2
      rc=$(grep -oE '__EXIT=[0-9]+' "$OUT/full_restore.out" | tail -n1 | cut -d= -f2); rc=${rc:-99}
      grep -q "^$(md5sum < "$OUT/sql/full_restore.sql" | cut -c1-32) " "$OUT/full_restore.out" || echo "WARNING: uploaded file md5 not confirmed"
    fi
    mark "full_restore end rc=$rc"
    grep -E 'ERROR|RESTORE' "$OUT/full_restore.out"
    [[ $rc == 0 ]] && grep -q 'RESTORE|PASS' "$OUT/full_restore.out" || die "full restore did not commit (see $OUT/full_restore.out; one transaction: nothing changed)"
    echo "RESTORE|PASS"
    # after the restore: delete again what the deletion log lists (idempotent), then verify 0
    if ls "$KODHANE_DL_DIR"/kodhane-deletion-log-*.csv > /dev/null 2>&1; then
      KODHANE_OUT="$OUT" bash "$HERE/kodhane_deletion_log_reapply.sh" reapply || die "RESTORE committed, deletion log reapply did NOT pass: deleted accounts may be back. Fix the cause (install migration 20261003040000 if the backup predates it: kodhane_deletion_log_install.sh), then run kodhane_deletion_log_reapply.sh reapply and verify (runbook)"
      KODHANE_OUT="$OUT" bash "$HERE/kodhane_deletion_log_reapply.sh" verify || die "RESTORE committed, deletion log verify FAILED (see $OUT/deletion_log_verify.out)"
      echo "RESTORE|DELETION_LOG|PASS"
    else echo "RESTORE|DELETION_LOG|no export files in $KODHANE_DL_DIR: nothing to reapply"; fi ;;
  *) usage ;;
esac
