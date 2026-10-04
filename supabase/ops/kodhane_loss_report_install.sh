#!/usr/bin/env bash
# Kayıp bildir (v4.5 P7, migration 20261003060000): SEPARATE install step with its own approval. Not part of package B and
# not part of v4.4-backend: run it from a v4.5-kayip-bildir checkout, after B + progress log are live. Runbook:
# docs/kodhane-loss-report-runbook.md. Steps (one run directory $KODHANE_OUT):
#   build        input md5s (kodhane_loss_report/inputs.md5) INCLUDING the account delete files of this branch, delete-script
#                check, generate the SQL into $KODHANE_OUT/sql (+ sql.md5)
#   delete-script-check  the account delete files that will be used from install day on ($KODHANE_ACCOUNT_DELETE_DIR,
#                default: this checkout's supabase/ops) must be this branch's loss-report-aware version (md5 + markers).
#                The old be96e03 script leaves reports behind (kodhane_only) or stops (full): STOP. Run by build,
#                preflight, install and verify too.
#   preflight    READ ONLY: target (Kodhane, not Fenomen), B + progress log enabled, existing objects
#   dryrun       migration + install check in one transaction, ROLLBACK
#   install      the same with COMMIT (needs PASS of preflight and dryrun in this run directory; live: KODHANE_LIVE_APPROVAL)
#   verify       READ ONLY install check (9 checks) + account delete preflight of a non-existent uid from
#                $KODHANE_ACCOUNT_DELETE_DIR must list kodhane_loss.loss_report as delete|delete + delete check
#                (kodhane_loss_report/delete_check.sql, ONE transaction ending with ROLLBACK: two synthetic auth users +
#                reports, the DO block of $KODHANE_ACCOUNT_DELETE_DIR/kodhane_account_delete.sql verbatim in both modes,
#                the auth user delete (FK cascade) and the 12-month cleanup, each undone; DELCHECK|PASS|5 needed)
#   rollback     rollback file (refuses while reports exist unless KODHANE_ALLOW_LOSS_REPORT_LOSS=on; live: approval)
# Target: KODHANE_TARGET=local (KODHANE_CT, KODHANE_DB) | live (PORTAINER_API_TOKEN, pexec), see kodhane_deletion_log/lib.sh.
# No backup step of its own (the migration only adds objects); take the usual DB backup first if it is not recent.
# Exit 0 = step PASS; 1 = STOP / FAIL; 2 = usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SB="$(cd "$HERE/.." && pwd)"; D="$HERE/kodhane_loss_report"
. "$HERE/kodhane_deletion_log/lib.sh"
MIG=migrations/20261003060000_v4_5_kodhane_loss_report.sql; RB=rollback/20261003060000_v4_5_kodhane_loss_report.rollback.sql
ADIR="${KODHANE_ACCOUNT_DELETE_DIR:-$HERE}"
STEP="${1:-}"; OUT="${KODHANE_OUT:-}"
usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
[[ -n "$STEP" ]] || usage
[[ -n "$OUT" ]] || dl_die "KODHANE_OUT (run directory) is required"
umask 077; mkdir -p "$OUT/sql"; chmod 700 "$OUT"
mark() { echo "$(dl_ts) $STEP $*" >> "$OUT/times.txt"; }
need_pass() { [[ -f "$OUT/$1" ]] && grep -Eq "$2" "$OUT/$1" || dl_die "$1 has no $2 in $OUT (run that step first)"; }
need_approval() {
  [[ "$DL_TARGET" == local ]] && return 0
  [[ -n "${KODHANE_LIVE_APPROVAL:-}" ]] || dl_die "live $STEP needs KODHANE_LIVE_APPROVAL (who approved, when)"
  mark "approval: $KODHANE_LIVE_APPROVAL"
}
# the account delete script of install day: same bytes as reviewed here (inputs.md5) + loss-report markers
delete_script_check() {
  local f exp got bad=0
  for f in kodhane_account_delete.sql kodhane_account_delete_preflight.sql kodhane_account_delete_verify.sql kodhane_deletion_log/reapply.sql; do
    exp=$(grep -E " ops/$f\$" "$D/inputs.md5" | cut -c1-32); got=$(md5sum < "$ADIR/$f" 2>/dev/null | cut -c1-32)
    if [[ -z "$exp" || "$exp" != "$got" ]]; then echo "DELETECHECK|FAIL|$f|md5 ${got:-missing} (expected $exp: the v4.5-kayip-bildir version)"; bad=1
    else echo "DELETECHECK|ok|$f|$got"; fi
  done
  grep -q "K3c. Kayıp bildir reports (kodhane_loss.loss_report" "$ADIR/kodhane_account_delete.sql" 2>/dev/null \
    || { echo "DELETECHECK|FAIL|kodhane_account_delete.sql|no K3c loss report step (old be96e03 script?)"; bad=1; }
  grep -q "'kodhane_loss.loss_report', 'auth.sessions'" "$ADIR/kodhane_account_delete_verify.sql" 2>/dev/null \
    || { echo "DELETECHECK|FAIL|kodhane_account_delete_verify.sql|does not check kodhane_loss.loss_report"; bad=1; }
  [[ $bad == 0 ]] && { echo "DELETECHECK|PASS|$ADIR"; return 0; }
  echo "STOP: the account delete script in $ADIR is not the loss-report-aware version of this branch; switch it first (runbook: zorunlu adım)"; return 1
}
# pg_temp.kodhane_del_run() = the DO block of the account delete file, verbatim (as kodhane_deletion_log/build_reapply.py does)
delete_block() { python3 - "$1" <<'PY'
import sys
src = open(sys.argv[1]).read().split('\n')
b = [i for i, l in enumerate(src) if l == 'do $del$']; e = [i for i, l in enumerate(src) if l == 'end $del$;']
assert len(b) == 1 and len(e) == 1 and b[0] < e[0], 'DO block of ' + sys.argv[1] + ' not found'
print('-- ======== pg_temp.kodhane_del_run(): DO block of ' + sys.argv[1].split('/')[-1] + ', verbatim')
print('create or replace function pg_temp.kodhane_del_run() returns void language plpgsql as $del$')
print('\n'.join(src[b[0] + 1:e[0] + 1]))
PY
}
strip_tx() { python3 - "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split('\n')
b = [i for i, l in enumerate(lines) if l == 'begin;']; c = [i for i, l in enumerate(lines) if l == 'commit;']
assert len(b) == 1 and len(c) == 1 and b[0] < c[0], 'expected exactly one top-level begin; / commit; in ' + sys.argv[1]
print('\n'.join(l if i not in (b[0], c[0]) else '-- (' + l + ' removed: runs inside the install transaction)' for i, l in enumerate(lines)))
PY
}
run() {  # run <name>
  local f="$OUT/sql/$1.sql" rc; [[ -r "$f" ]] || dl_die "missing $f (run build)"
  mark "$1 start ($(md5sum < "$f" | cut -c1-32))"; dl_run_sql "$f" "$OUT/$1.out"; rc=$?; mark "$1 end rc=$rc"; return $rc
}
if [[ "$STEP" == delete-script-check ]]; then delete_script_check | tee "$OUT/delete-script-check.out"; exit "${PIPESTATUS[0]}"; fi
dl_target_init
case "$STEP" in
  build)
    ( cd "$SB" && md5sum --quiet -c "$D/inputs.md5" ) || dl_die "input files differ from kodhane_loss_report/inputs.md5 (reviewed versions)"
    delete_script_check > "$OUT/delete-script-check.out" || { cat "$OUT/delete-script-check.out"; dl_die "delete-script-check failed"; }
    S="$OUT/sql"
    { echo "-- generated by kodhane_loss_report_install.sh build: preflight (READ ONLY)"; echo "$DL_PREFIX"; echo "begin read only;"
      cat "$D/preflight.sql"; echo "commit;"; echo "select 'PREFLIGHT|PASS';"; } > "$S/preflight.sql"
    for k in dryrun install; do
      { echo "-- generated by kodhane_loss_report_install.sh build: $k (migration 20261003060000 + install check, one transaction)"
        echo "$DL_PREFIX"; echo "begin;"; echo "set local lock_timeout = '5s';"; strip_tx "$SB/$MIG" || exit 1; cat "$D/install_verify.sql" | grep -vE '^(begin transaction read only;|rollback;)$'
        if [[ $k == dryrun ]]; then echo "rollback;"; echo "select 'DRYRUN|PASS|rolled back';"; else echo "commit;"; echo "select 'INSTALL|PASS|committed';"; fi
      } > "$S/$k.sql" || dl_die "build failed"
    done
    { echo "-- generated by kodhane_loss_report_install.sh build: verify (READ ONLY)"; echo "$DL_PREFIX"
      cat "$D/install_verify.sql"; echo "select 'VERIFY|PASS';"; } > "$S/verify.sql"
    { echo "-- generated by kodhane_loss_report_install.sh build: delete path (account delete preflight, READ ONLY, uid that does not exist)"
      echo "$DL_PREFIX"; echo '\set uid 00000000-0000-4000-8000-00000000d71e'; cat "$ADIR/kodhane_account_delete_preflight.sql"; } > "$S/delete_path.sql"
    { echo "-- generated by kodhane_loss_report_install.sh build: delete check (ONE transaction, ends with ROLLBACK; nothing stays)"
      echo "$DL_PREFIX"; echo "begin;"; echo "set local lock_timeout = '5s';"; echo "set local statement_timeout = '120s';"
      delete_block "$ADIR/kodhane_account_delete.sql" || exit 1
      cat "$D/delete_check.sql"; echo "rollback;"; echo "select 'DELCHECK|END|rolled back';"; } > "$S/delete_check.sql" || dl_die "build failed"
    for loss in no yes; do
      { echo "-- generated by kodhane_loss_report_install.sh build: rollback"; echo "$DL_PREFIX"; echo "begin;"
        [[ $loss == yes ]] && echo "set local kodhane.loss_report_allow_loss = on;   -- KODHANE_ALLOW_LOSS_REPORT_LOSS=on: the reports are dropped"
        strip_tx "$SB/$RB" || exit 1
        echo "select 'CHECK|rolled_back|' || (to_regnamespace('kodhane_loss') is null and to_regprocedure('public.kodhane_loss_report_status(integer)') is null);"
        echo "commit;"; echo "select 'ROLLBACK|PASS|committed';"; } > "$S/rollback$([[ $loss == yes ]] && echo _allow_loss).sql" || dl_die "build failed"
    done
    ( cd "$S" && md5sum preflight.sql dryrun.sql install.sql verify.sql delete_path.sql delete_check.sql rollback.sql rollback_allow_loss.sql > ../sql.md5 )
    { echo "BUILD|PASS"; ( cd "$SB" && md5sum $MIG $RB ); cat "$OUT/sql.md5"; } | tee "$OUT/build.out" ;;
  preflight)
    delete_script_check > "$OUT/delete-script-check.out" || { cat "$OUT/delete-script-check.out"; dl_die "delete-script-check failed"; }
    run preflight; rc=$?; grep -E '^INFO\|' "$OUT/preflight.out"; grep -oE '(STOP|ERROR): .*' "$OUT/preflight.out"
    [[ $rc == 0 ]] && grep -q '^PREFLIGHT|PASS' "$OUT/preflight.out" || dl_die "preflight did not pass (see $OUT/preflight.out)"
    echo "PREFLIGHT|PASS" ;;
  dryrun|install|verify)
    delete_script_check > "$OUT/delete-script-check.out" || { cat "$OUT/delete-script-check.out"; dl_die "delete-script-check failed"; }
    [[ $STEP == dryrun ]] && need_pass preflight.out '^PREFLIGHT\|PASS'
    if [[ $STEP == install ]]; then need_approval; need_pass preflight.out '^PREFLIGHT\|PASS'; need_pass dryrun.out '^DRYRUN\|PASS'; fi
    ( cd "$OUT/sql" && md5sum --quiet -c ../sql.md5 ) || dl_die "generated SQL changed since build"
    run $STEP; rc=$?; grep -E '^(CHECK|LRVERIFY)\|' "$OUT/$STEP.out"; grep -oE 'ERROR: .*' "$OUT/$STEP.out" | head -n3
    U=$(echo $STEP | tr a-z A-Z)
    [[ $rc == 0 ]] && grep -q "^$U|PASS" "$OUT/$STEP.out" || dl_die "$STEP did not pass (see $OUT/$STEP.out; nothing committed if the error came before COMMIT)"
    if [[ $STEP == verify ]]; then
      run delete_path; rc=$?
      grep -qE '^kodhane\|kodhane_loss\.loss_report\|user_id\|0\|delete\|delete$' "$OUT/delete_path.out" && [[ $rc == 0 ]] \
        || dl_die "delete path: the account delete preflight of $ADIR does not list kodhane_loss.loss_report as delete|delete (see $OUT/delete_path.out)"
      echo "CHECK|delete_path|t|account delete preflight lists kodhane_loss.loss_report delete|delete"
      run delete_check; rc=$?; grep -E '^(CHECK|DELCHECK)\|' "$OUT/delete_check.out"; grep -oE '(STOP|ERROR): .*' "$OUT/delete_check.out" | head -n3
      [[ $rc == 0 ]] && grep -qE '^DELCHECK\|PASS\|5$' "$OUT/delete_check.out" && grep -q '^DELCHECK|END|rolled back' "$OUT/delete_check.out" \
        || dl_die "delete check did not pass: account deletion does not remove the reports on this database (see $OUT/delete_check.out; rolled back)"
    fi
    echo "$U|PASS" ;;
  rollback)
    need_approval; f=rollback; [[ "${KODHANE_ALLOW_LOSS_REPORT_LOSS:-}" == on ]] && f=rollback_allow_loss
    ( cd "$OUT/sql" && md5sum --quiet -c ../sql.md5 ) || dl_die "generated SQL changed since build"
    run $f; rc=$?; grep -E '^CHECK\|' "$OUT/$f.out"; grep -oE 'ERROR: .*' "$OUT/$f.out" | head -n3
    [[ $rc == 0 ]] && grep -q '^ROLLBACK|PASS' "$OUT/$f.out" || dl_die "rollback did not commit (see $OUT/$f.out)"
    echo "ROLLBACK|PASS" ;;
  *) usage ;;
esac
