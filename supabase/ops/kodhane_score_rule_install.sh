#!/usr/bin/env bash
# Kodhane v4.5 skor kuralı (migration 20261003080000): SEPARATE install step with its own approval, AFTER package B
# (v4.4-backend) and BEFORE the v4.5 client push. Order: B -> this (verified live) -> v4.5 push. Run it from a
# v4.5-kayip-bildir checkout (the score rule is a separate commit there). Runbook: docs/kodhane-v4.5-score-rule-runbook.md. Steps (one run directory $KODHANE_OUT):
#   build      input md5s (kodhane_score_rule/inputs.md5), generate the SQL into $KODHANE_OUT/sql (+ sql.md5)
#   preflight  READ ONLY: target (Kodhane, not Fenomen), B installed + version guard on; dry run of the v4.5 rule on
#              every real save (the migration's function body as a query, curve = literal of row v45_f2): counts
#              plausible now / with v4.5 / became_true; STOP if any save plausible now would become implausible;
#              INFO|stage_1e21_backfill_candidates|n = rows whose best_stage_id the install sets to asama_1e21 (live: 0)
#   dryrun     pre-check snapshot + migration + postcheck (no save may become implausible, nobody leaves the
#              leaderboard) + verify in one transaction, ROLLBACK; prints INFO|stage_1e21_backfill|rows|n
#   install    the same with COMMIT (needs PASS of preflight and dryrun in this run directory; live: KODHANE_LIVE_APPROVAL)
#   verify     READ ONLY: 14 checks (definition md5, privileges, one active row = v45_f2, vectors, B objects unchanged,
#              stage catalogue with asama_1e21, backfill complete, stage log closed, proconfig search_path + jit=off)
#   rollback-preview  READ ONLY: the rows the rollback will write (best_stage_id asama_1e21 -> logged value before),
#              RBJIT = jit=off is removed; RBCOUNT + RBROW lines in rollback_preview.out, the same as TSV in rollback_rows.tsv (user_id, now, back to, source)
#   rollback   (needs rollback-preview in this run directory; live: approval) prints the rows again before writing,
#              puts best_stage_id back, stage catalogue + CHECK back to B, v4.4b definition, schema kodhane_rule dropped;
#              CHECK|rollback_rows_restored|t|n = every recorded row has its value before; CHECK|rollback_no_jit_setting|t
# Target: KODHANE_TARGET=local (KODHANE_CT, KODHANE_DB) | live (PORTAINER_API_TOKEN, pexec), see kodhane_deletion_log/lib.sh.
# No backup step of its own (one function replaced, one small schema added; rollback restores B byte for byte);
# take the usual DB backup first if it is not recent. Exit 0 = step PASS; 1 = STOP / FAIL; 2 = usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SB="$(cd "$HERE/.." && pwd)"; D="$HERE/kodhane_score_rule"
. "$HERE/kodhane_deletion_log/lib.sh"
MIG=migrations/20261003080000_v4_5_kodhane_score_rule.sql; RB=rollback/20261003080000_v4_5_kodhane_score_rule.rollback.sql
STEP="${1:-}"; OUT="${KODHANE_OUT:-}"
usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
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
strip_tx() { python3 - "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split('\n')
b = [i for i, l in enumerate(lines) if l == 'begin;']; c = [i for i, l in enumerate(lines) if l == 'commit;']
assert len(b) == 1 and len(c) == 1 and b[0] < c[0], 'expected exactly one top-level begin; / commit; in ' + sys.argv[1]
print('\n'.join(l if i not in (b[0], c[0]) else '-- (' + l + ' removed: runs inside the install transaction)' for i, l in enumerate(lines)))
PY
}
# the v4.5 function body between its markers, with the curve source line replaced by the literal of row v45_f2
body_query() { python3 - "$SB/$MIG" "$D/curve_literal.sql" <<'PY'
import sys
src = open(sys.argv[1]).read(); lit = open(sys.argv[2]).read().strip()
a, b = src.index('-- <v4_5_body>\n'), src.index('-- </v4_5_body>')
body = src[a + len('-- <v4_5_body>\n'):b]
mk = [l for l in body.split('\n') if l.rstrip().endswith('-- <score_curve_source>')]
assert len(mk) == 1 and mk[0].strip().startswith('cross join kodhane_rule.active_score_curve() c'), 'curve source marker'
print(body.replace(mk[0], '      ' + lit).rstrip().rstrip(';'))
PY
}
run() {  # run <name>
  local f="$OUT/sql/$1.sql" rc; [[ -r "$f" ]] || dl_die "missing $f (run build)"
  mark "$1 start ($(md5sum < "$f" | cut -c1-32))"; dl_run_sql "$f" "$OUT/$1.out"; rc=$?; mark "$1 end rc=$rc"; return $rc
}
dl_target_init
case "$STEP" in
  build)
    ( cd "$SB" && md5sum --quiet -c "$D/inputs.md5" ) || dl_die "input files differ from kodhane_score_rule/inputs.md5 (reviewed versions)"
    S="$OUT/sql"; BQ=$(body_query) || dl_die "cannot extract the v4.5 body from $MIG"
    { echo "-- generated by kodhane_score_rule_install.sh build: preflight (READ ONLY, dry run of the v4.5 rule on every save)"
      echo "$DL_PREFIX"; echo "begin read only;"; cat "$D/preflight_head.sql"
      echo "with s as (select k.user_id, k.data as d, k.best_stage_id, now() as p_now from public.kodhane_saves k),"
      echo "x as (select s.user_id, s.d, s.best_stage_id, coalesce(public.kodhane_score_plausible(s.d, s.p_now), false) as cur_ok, coalesce(("
      echo "$BQ"
      echo "), false) as new_ok from s)"
      echo "select concat_ws('|', 'INFO', 'dryrun', 'saves', count(*), 'plausible_now', count(*) filter (where cur_ok), 'plausible_v45', count(*) filter (where new_ok),"
      echo "                 'became_true', count(*) filter (where new_ok and not cur_ok), 'became_false', count(*) filter (where cur_ok and not new_ok))"
      echo "  || E'\\n' || case when count(*) filter (where cur_ok and not new_ok) = 0 then 'CHECK|dryrun_no_save_becomes_implausible|t'"
      echo "                  else 'STOP: ' || count(*) filter (where cur_ok and not new_ok) || ' save(s) plausible now would become implausible under v4.5' end"
      echo "  || E'\\n' || concat_ws('|', 'INFO', 'stage_1e21_backfill_candidates', count(*) filter (where new_ok and jsonb_typeof(d -> 'stageId') = 'string'"
      echo "       and d ->> 'stageId' = 'asama_1e21' and public.kodhane_save_score(d) >= 1e21 and best_stage_id is distinct from 'asama_1e21'"
      echo "       and best_stage_id is distinct from 'mars_ofisi'), 'rows whose best_stage_id the install sets to asama_1e21 (live before the v4.5 push: 0 expected)') from x;"
      echo "commit;"; } > "$S/preflight.sql" || dl_die "build failed"
    for k in dryrun install; do
      { echo "-- generated by kodhane_score_rule_install.sh build: $k (migration 20261003080000 + checks, one transaction)"
        echo "$DL_PREFIX"; echo "begin;"; echo "set local lock_timeout = '5s';"; cat "$D/pre_tx.sql"; strip_tx "$SB/$MIG" || exit 1
        cat "$D/postcheck.sql"; grep -vE '^(begin transaction read only;|rollback;)$' "$D/verify.sql"
        if [[ $k == dryrun ]]; then echo "rollback;"; echo "select 'DRYRUN|PASS|rolled back';"; else echo "commit;"; echo "select 'INSTALL|PASS|committed';"; fi
      } > "$S/$k.sql" || dl_die "build failed"
    done
    { echo "-- generated by kodhane_score_rule_install.sh build: verify (READ ONLY)"; echo "$DL_PREFIX"; cat "$D/verify.sql"; echo "select 'VERIFY|PASS';"; } > "$S/verify.sql"
    { echo "-- generated by kodhane_score_rule_install.sh build: rollback"; echo "$DL_PREFIX"; echo "begin;"; strip_tx "$SB/$RB" || exit 1
      echo "select 'CHECK|rolled_back|' || (to_regnamespace('kodhane_rule') is null and md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure)) = '463f2109c35b825827e57b8098b49947'"
      echo "  and md5(pg_get_functiondef('public.kodhane_stage_rank(text)'::regprocedure)) = 'e97a3589f1f23fe36991b986480bd509' and md5(pg_get_functiondef('public.kodhane_stage_at(text)'::regprocedure)) = 'b0aa4d9eb67eb4bb284d54c6641be791');"
      echo "select 'CHECK|rollback_no_jit_setting|' || case when exists (select 1 from pg_proc where oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure and coalesce(array_to_string(proconfig, ','), '') like '%jit=%') then 'f' else 't' end;"
      echo "commit;"; echo "select 'ROLLBACK|PASS|committed';"; } > "$S/rollback.sql" || dl_die "build failed"
    { echo "-- generated by kodhane_score_rule_install.sh build: rollback-preview (READ ONLY): rows the rollback will write"; echo "$DL_PREFIX"
      echo "begin transaction read only;"; cat "$D/rollback_preview.sql"; echo "rollback;"; echo "select 'RBPREVIEW|PASS';"; } > "$S/rollback_preview.sql" || dl_die "build failed"
    ( cd "$S" && md5sum preflight.sql dryrun.sql install.sql verify.sql rollback_preview.sql rollback.sql > ../sql.md5 )
    { echo "BUILD|PASS"; ( cd "$SB" && md5sum $MIG $RB ); cat "$OUT/sql.md5"; } | tee "$OUT/build.out" ;;
  preflight)
    ( cd "$OUT/sql" && md5sum --quiet -c ../sql.md5 ) || dl_die "generated SQL changed since build"
    run preflight; rc=$?; grep -E '^(INFO|CHECK)\|' "$OUT/preflight.out"; grep -oE '(STOP|ERROR): .*' "$OUT/preflight.out"
    [[ $rc == 0 ]] && ! grep -qE '(STOP|ERROR): ' "$OUT/preflight.out" && grep -q '^CHECK|dryrun_no_save_becomes_implausible|t' "$OUT/preflight.out" \
      || dl_die "preflight did not pass (see $OUT/preflight.out)"
    echo "PREFLIGHT|PASS" | tee -a "$OUT/preflight.out" ;;
  dryrun|install|verify)
    [[ $STEP == dryrun ]] && need_pass preflight.out '^PREFLIGHT\|PASS'
    if [[ $STEP == install ]]; then need_approval; need_pass preflight.out '^PREFLIGHT\|PASS'; need_pass dryrun.out '^DRYRUN\|PASS'; fi
    ( cd "$OUT/sql" && md5sum --quiet -c ../sql.md5 ) || dl_die "generated SQL changed since build"
    run $STEP; rc=$?; grep -E '^(INFO|CHECK|LB|SRVERIFY)\|' "$OUT/$STEP.out"; grep -oE 'ERROR: .*' "$OUT/$STEP.out" | head -n3
    U=$(echo $STEP | tr a-z A-Z)
    [[ $rc == 0 ]] && grep -q '^SRVERIFY|PASS' "$OUT/$STEP.out" && ! grep -q '^CHECK|[a-z_0-9]*|f' "$OUT/$STEP.out" && grep -q "^$U|PASS" "$OUT/$STEP.out" \
      || dl_die "$STEP did not pass (see $OUT/$STEP.out; nothing committed if the error came before COMMIT)"
    echo "$U|PASS" ;;
  rollback-preview)
    ( cd "$OUT/sql" && md5sum --quiet -c ../sql.md5 ) || dl_die "generated SQL changed since build"
    run rollback_preview; rc=$?; grep -E '^(RBJIT|RBCOUNT)\|' "$OUT/rollback_preview.out"; grep -oE 'ERROR: .*' "$OUT/rollback_preview.out" | head -n3
    [[ $rc == 0 ]] && grep -q '^RBPREVIEW|PASS' "$OUT/rollback_preview.out" || dl_die "rollback-preview failed (see $OUT/rollback_preview.out)"
    { printf 'user_id\tbest_stage_id_now\tback_to\tsource\n'; grep '^RBROW|' "$OUT/rollback_preview.out" | cut -d'|' -f2- | tr '|' '\t'; } > "$OUT/rollback_rows.tsv"
    echo "RBPREVIEW|PASS|$(grep -c '^RBROW|' "$OUT/rollback_preview.out") row(s) recorded in $OUT/rollback_rows.tsv" ;;
  rollback)
    need_approval; need_pass rollback_preview.out '^RBPREVIEW\|PASS'
    ( cd "$OUT/sql" && md5sum --quiet -c ../sql.md5 ) || dl_die "generated SQL changed since build"
    run rollback; rc=$?; grep -E '^(CHECK|RBCOUNT)\|' "$OUT/rollback.out"; grep -oE 'ERROR: .*' "$OUT/rollback.out" | head -n3
    [[ $rc == 0 ]] && grep -q '^ROLLBACK|PASS' "$OUT/rollback.out" && grep -q '^CHECK|rolled_back|t' "$OUT/rollback.out" \
      && grep -q '^CHECK|rollback_rows_restored|t' "$OUT/rollback.out" && grep -q '^CHECK|rollback_no_jit_setting|t' "$OUT/rollback.out" || dl_die "rollback did not commit (see $OUT/rollback.out)"
    if diff -q <(grep '^RBROW|' "$OUT/rollback_preview.out") <(grep '^RBROW|' "$OUT/rollback.out") >/dev/null; then echo "INFO|rollback_rows_vs_preview|same"
    else echo "INFO|rollback_rows_vs_preview|differs (rows changed after the preview; rollback.out RBROW lines are the rows written)"; fi
    echo "ROLLBACK|PASS" ;;
  *) usage ;;
esac
