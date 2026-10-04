#!/usr/bin/env bash
# Kodhane deletion log (silme listesi, migration 20261003040000) tests: separate install step, list row written by the
# account delete in the same transaction (full = scope account, kodhane_only = scope kodhane), export (box files 600 /
# dir 700, no overwrite, unchanged = no file, prune), restore + reapply + verify (via kodhane_v44b_install.sh restore:
# last list from the current DB first), idempotence, other users unchanged, bad / damaged files refused, Kodhane scope
# "played again" / mixed, block, retention (cleanup function, Dokploy command variants, daily script).
# LOCAL THROWAWAY DATABASES ONLY, docker container $DL_CT (supabase/postgres image) whose database $DL_BASE holds the live
# schema after v2.2 (no data). Drops / creates databases; renames the container's postgres database for the T3 tests.
#   DL_CT=<container> bash supabase/tests/deletion_log/run_kodhane_deletion_log_tests.sh 2>&1 | tee /tmp/dl-test.log
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; OPS="$ROOT/ops"
CT="${DL_CT:-v44x-136}"; BASE="${DL_BASE:-v44_base}"; OUT="${DL_OUT:-/tmp/dl-test}"; rm -rf "$OUT"; mkdir -p "$OUT"; chmod 700 "$OUT"
MIGA="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"; MIGB="$ROOT/migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql"
MIGL="$ROOT/migrations/20261003020000_v4_4_kodhane_progress_log.sql"; MIGR="$ROOT/migrations/20261001210000_v4_4_kodhane_audit_log_retention.sql"
MIGD="$ROOT/migrations/20261003040000_v4_4_kodhane_deletion_log.sql"; RBD="$ROOT/rollback/20261003040000_v4_4_kodhane_deletion_log.rollback.sql"
DEL="$OPS/kodhane_account_delete.sql"; PRE="$OPS/kodhane_account_delete_preflight.sql"; VER="$OPS/kodhane_account_delete_verify.sql"
EXP="$OPS/kodhane_deletion_log_export.sh"; REA="$OPS/kodhane_deletion_log_reapply.sh"; INS="$OPS/kodhane_deletion_log_install.sh"; B="$OPS/kodhane_v44b_install.sh"
U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222; U3=33333333-3333-4333-8333-333333333333
U4=44444444-4444-4444-8444-444444444444
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
PA() { P -At -F '|' "$@"; }
PG() { docker exec -i "$CT" psql -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }
FAILS=0; PASSN=0; declare -A NT=()
pass() { echo "PASS $*"; PASSN=$((PASSN+1)); local k=${1%%[0-9]*}; NT[$k]=$(( ${NT[$k]:-0} + 1 )); }
fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1  -- $2"; else fail "$1: got [$2] expected [$3]"; fi; }
mkdb() {   # mkdb <db> [dl]: base + A + B + progress log + test seed (+ deletion log migration)
  P -d postgres -c "drop database if exists $1 with (force)" -c "create database $1 template $BASE" >/dev/null 2>&1 || return 1
  P -d $1 -1 -f - < "$MIGA" >/dev/null 2>&1 && P -d $1 -1 -f - < "$MIGB" >/dev/null 2>&1 && P -d $1 -f - < "$MIGL" >/dev/null 2>&1 || return 1
  P -d $1 -f - < "$ROOT/tests/fixtures/helpers.sql" >/dev/null && P -d $1 -f - < "$ROOT/tests/account_delete/seed.sql" >/dev/null \
    && P -d $1 -f - < "$ROOT/tests/account_delete/snap.sql" >/dev/null && P -d $1 -f - < "$HERE/fp.sql" >/dev/null || return 1
  [[ "${2:-}" == dl ]] && { P -d $1 -f - < "$MIGD" >/dev/null 2>&1 || return 1; }
  return 0
}
token() { PA -d "$1" -v uid="$2" -f - < "$PRE" 2>&1 | grep -E '^(OK|BLOCKED|STOP):' | awk -F'|' '{print $NF}'; }
del() { local db=$1 log=$2 mode=$3 u=$4 ref=$5; P -d "$db" -v mode=$mode -v uid=$u -v confirm_uid=$u -v approval_ref="$ref" -v expect="$(token $db $u)" -f - < "$DEL" > "$OUT/$log" 2>&1; }
fp() { PA -d "$1" -c "select rel || '=' || h from t.dl_fp('{$2}'::uuid[])"; }
user_n() { PA -d "$1" -c "select string_agg(rel || '=' || n, ' ' order by rel) filter (where n > 0) from t.dl_user('$2')"; }
dl_rows() { PA -d "$1" -c "select coalesce(string_agg(left(user_id::text, 8) || '/' || scope || '/' || approval_ref, ' ' order by user_id, scope), '-') from kodhane_private.deletion_log"; }
data_md5() { docker exec "$CT" pg_dump -U supabase_admin --data-only -d "$1" | grep -vE '^(--|\\(un)?restrict |SET |SELECT pg_catalog.set_config)' | md5sum | cut -c1-32; }
dumpfc() { docker exec "$CT" pg_dump -U supabase_admin -Fc -d "$1" > "$2" && chmod 600 "$2" && ( cd "$(dirname "$2")" && md5sum "$(basename "$2")" > "$(basename "$2").md5" ); }
L() { KODHANE_TARGET=local KODHANE_CT="$CT" KODHANE_DB="$1" "${@:2}"; }   # L <db> <command...>
export -f L 2>/dev/null
echo "== image: $(docker inspect "$CT" --format '{{.Config.Image}}'); base: $BASE"

# ------------------------------------------------------------------ M: migration = separate install step
mkdb dl_main || { echo "setup failed"; exit 1; }
P -d dl_main -c "create schema if not exists dlt_probe" >/dev/null; P -d dl_main -c "drop schema dlt_probe" >/dev/null
docker exec "$CT" pg_dump -U supabase_admin --schema-only -d dl_main | grep -v '^\\\(un\)\?restrict ' > "$OUT/schema_before.sql"
o=""; for s in build preflight dryrun; do o="$o $(KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/ins bash "$INS" $s | grep -E '^[A-Z]+\|PASS' | tail -n1)"; done
check "M1 install step (local): build, preflight, dry run PASS; after the dry run nothing exists" "$o|$(PA -d dl_main -c "select to_regnamespace('kodhane_private') is null")" " BUILD|PASS PREFLIGHT|PASS DRYRUN|PASS|t"
grep -q "^$(md5sum < "$MIGD" | cut -c1-32)  migrations/20261003040000" "$OUT/ins/build.out" && pass "M1b build pins the migration md5 ($(md5sum < "$MIGD" | cut -c1-12))" || fail "M1b migration md5 not in build.out"
o=""; for s in install verify; do o="$o $(KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/ins bash "$INS" $s | tail -n1)"; done
check "M2 install + verify PASS (12 install checks: owner, ACLs, columns, CHECKs, RLS forced, 45 days, functions)" "$o|$(grep -c '^CHECK|.*|t|' "$OUT/ins/verify.out")" " INSTALL|PASS VERIFY|PASS|12"
P -d dl_main -f - < "$MIGD" >/dev/null 2>&1 && o=$(KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/ins bash "$INS" verify | tail -n1)
check "M3 migration again (idempotent), verify still PASS" "$o" "VERIFY|PASS"
r=""; for role in anon authenticated service_role; do
  x=$(P -d dl_main -c "set role $role" -c "select count(*) from kodhane_private.deletion_log" 2>&1 | grep -oE 'permission denied for schema kodhane_private' | head -n1)
  y=$(P -d dl_main -c "set role $role" -c "select kodhane_private.cleanup_deletion_log()" 2>&1 | grep -oE 'permission denied for schema kodhane_private' | head -n1)
  r="$r $role:${x:+denied}/${y:+denied}"; done
check "M4 anon / authenticated / service_role: table and cleanup function -> permission denied" "$r" " anon:denied/denied authenticated:denied/denied service_role:denied/denied"
r=$(PG -d dl_main -c "select count(*) from kodhane_private.deletion_log" 2>&1)
check "M4b postgres (owner, BYPASSRLS) reads the forced-RLS table" "$r" "0"
r=""; for v in "'info:x@example.invalid'" "'info:a,b'" "'info:'" "'TEST-ONAY'" ; do
  P -d dl_main -c "insert into kodhane_private.deletion_log (user_id, scope, approval_ref) values (gen_random_uuid(), 'account', $v)" >/dev/null 2>&1 && r="$r ok" || r="$r refused"; done
P -d dl_main -c "insert into kodhane_private.deletion_log (user_id, scope, approval_ref) values (gen_random_uuid(), 'acik_ofis', 'info:x')" >/dev/null 2>&1 && r="$r ok" || r="$r refused"
check "M5 CHECKs: e-mail, comma, empty ref, ref without prefix, unknown scope -> refused" "$r" " refused refused refused refused refused"
P -d dl_main -c "insert into kodhane_private.deletion_log (user_id, scope, approval_ref) values ('$U2', 'account', 'info:rb-test')" >/dev/null
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/ins bash "$INS" rollback > "$OUT/m6a.out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q 'the list has 1 row(s) that would be lost' "$OUT/m6a.out" && [[ $(PA -d dl_main -c "select count(*) from kodhane_private.deletion_log") == 1 ]] \
  && pass "M6 rollback refuses while the list has rows (nothing dropped)" || fail "M6 rc $rc $(cat "$OUT/m6a.out")"
o=$(KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/ins KODHANE_ALLOW_DELETION_LOG_LOSS=on bash "$INS" rollback | tail -n1)
docker exec "$CT" pg_dump -U supabase_admin --schema-only -d dl_main | grep -v '^\\\(un\)\?restrict ' > "$OUT/schema_after_rb.sql"
check "M6b rollback with KODHANE_ALLOW_DELETION_LOG_LOSS=on: schema back to before the install (diff lines)" "$o|$(diff "$OUT/schema_before.sql" "$OUT/schema_after_rb.sql" | grep -c '^[<>]')" "ROLLBACK|PASS|0"
P -d dl_main -f - < "$RBD" >/dev/null 2>&1 && pass "M6c rollback twice (idempotent)" || fail "M6c"
( KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/bbuild bash "$B" build > "$OUT/bbuild.out" 2>&1 )
bi=$(md5sum < "$OUT/bbuild/sql/install.sql" | cut -c1-32)
check "M7 package B install.sql unchanged (deefef0e...) and without the deletion log" "$bi|$(grep -c 'deletion_log' "$OUT/bbuild/sql/install.sql")" "deefef0e5c52cc3679dc997374d2edbb|0"
grep -q '^BUILD|PASS' "$OUT/bbuild.out" && pass "M7b package B build PASS (inputs.md5 pins the new account delete files)" || fail "M7b $(head -3 "$OUT/bbuild.out")"
P -d dl_main -f - < "$MIGD" >/dev/null 2>&1 || fail "M re-install"

# ------------------------------------------------------------------ D: the account delete writes the list (same transaction)
dumpfc dl_main "$OUT/pre.dump"     # the "nightly backup" BEFORE the deletions
FP0=$(fp dl_main "$U1,$U3,$U4"); U3K0=$(PA -d dl_main -c "select rel || '=' || h from t.snap_of('$U3')")
del dl_main d1.log full $U1 TEST-ONAY-1; rc=$?
check "D1 full delete: list row (scope account, info: prefix), notice" "$rc|$(dl_rows dl_main)|$(grep -oE 'deletion log row written \(scope account\)' "$OUT/d1.log")" "0|11111111/account/info:TEST-ONAY-1|deletion log row written (scope account)"
r=$(PA -d dl_main -c "select (deleted_at between now() - interval '1 minute' and now())::text from kodhane_private.deletion_log where user_id = '$U1'")
check "D1b deleted_at = time of the delete transaction" "$r" "true"
del dl_main d2.log kodhane_only $U3 TEST-ONAY-3; rc=$?
check "D2 kodhane_only delete: second row (scope kodhane)" "$rc|$(dl_rows dl_main)" "0|11111111/account/info:TEST-ONAY-1 33333333/kodhane/info:TEST-ONAY-3"
P -d dl_main -v mode=full -v uid=$U1 -f - < "$VER" > "$OUT/d3a.log" 2>&1; ra=$?; P -d dl_main -v mode=kodhane_only -v uid=$U3 -f - < "$VER" > "$OUT/d3b.log" 2>&1; rb=$?
check "D3 account delete verify: listed (both modes)" "$ra$rb|$(grep -oE 'deletion log: listed \(scope [a-z]+\)' "$OUT/d3a.log" "$OUT/d3b.log" | cut -d: -f2- | tr '\n' ' ')" "00|deletion log: listed (scope account) deletion log: listed (scope kodhane) "
s0=$(fp dl_main ""); n0=$(dl_rows dl_main)
for ref in 'TEST@example.invalid' 'TEST,ONAY'; do
  del dl_main d4.log full $U4 "$ref"; rc=$?
  [[ $rc != 0 ]] && grep -q 'approval_ref must be at most 200 characters without @' "$OUT/d4.log" && [[ "$(fp dl_main "")" == "$s0" && "$(dl_rows dl_main)" == "$n0" ]] \
    && pass "D4 approval_ref '$ref' -> refused, nothing deleted, no list row" || fail "D4 $ref rc $rc $(grep -m1 ERROR "$OUT/d4.log")"
done
P -d dl_main -c "create or replace function t.boom() returns trigger language plpgsql as \$\$ begin raise exception 'dl test: injected failure'; end \$\$" \
  -c "create trigger dl_boom before delete on auth.users for each row execute function t.boom()" >/dev/null
del dl_main d5.log full $U4 TEST-ONAY-4; rc=$?
[[ $rc != 0 ]] && grep -q 'injected failure' "$OUT/d5.log" && [[ "$(fp dl_main "")" == "$s0" && "$(dl_rows dl_main)" == "$n0" ]] \
  && pass "D5 delete fails at the last step (auth.users) -> rolled back, no list row (same transaction)" || fail "D5 rc $rc"
P -d dl_main -c "drop trigger dl_boom on auth.users" -c "drop function t.boom()" >/dev/null
mkdb dl_nolog || fail "setup dl_nolog"
del dl_nolog d6.log full $U1 TEST-ONAY-1; rc=$?
check "D6 without the migration the delete works as before (no row)" "$rc|$(grep -oE 'deletion log not installed \(no row\)' "$OUT/d6.log")" "0|deletion log not installed (no row)"
P -d dl_nolog -v mode=full -v uid=$U1 -f - < "$VER" > "$OUT/d6v.log" 2>&1 && grep -q 'deletion log: not installed' "$OUT/d6v.log" && pass "D6b verify without the migration: OK, 'not installed'" || fail "D6b"

# ------------------------------------------------------------------ X: export
XD="$OUT/box/kodhane-deletion-log"
x() { KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=${XDB:-dl_main} KODHANE_DL_DIR="$XD" bash "$EXP" > "$OUT/$1" 2>&1; echo $?; }
rc=$(x x1.out); F1=$(ls -1 "$XD"/*.csv | tail -n1)
check "X1 export: exit 0, dir 700, csv 600, md5 600, 2 rows, header" "$rc|$(stat -c %a "$XD")|$(stat -c %a "$F1")|$(stat -c %a "$F1.md5")|$(($(wc -l < "$F1") - 1))|$(head -n1 "$F1")" "0|700|600|600|2|user_id,scope,deleted_at_utc,approval_ref"
( cd "$XD" && md5sum --quiet -c "$(basename "$F1").md5" ) && ! grep -q '@' "$F1" && ! grep -qiE 'silinecek|example' "$F1" && pass "X1b md5 file matches; no e-mail / nickname in the file" || fail "X1b"
rc=$(x x2.out)
check "X2 second export, list unchanged: no new file" "$rc|$(ls -1 "$XD"/*.csv | wc -l)|$(grep -c unchanged "$OUT/x2.out")" "0|1|1"
P -d dl_main -c "insert into kodhane_private.deletion_log (user_id, scope, deleted_at, approval_ref) values ('99999999-9999-4999-8999-999999999999', 'account', now(), 'info:X3')" >/dev/null
kc=0; for i in 0 1 2 3; do n="$XD/kodhane-deletion-log-$(date -u -d "+$i seconds" +%Y%m%dT%H%M%SZ).csv"; [[ -e "$n" ]] || { echo "keep me" > "$n"; chmod 600 "$n"; kc=$((kc + 1)); }; done
rc=$(x x3.out)
check "X3 the new file name exists already -> exit 4, not overwritten" "$rc|$(grep -c 'not overwritten' "$OUT/x3.out")|$(cat "$XD"/*.csv | grep -c 'keep me')" "4|1|$kc"
for f in "$XD"/*.csv; do grep -q 'keep me' "$f" && rm -f "$f"; done
OLD="$XD/kodhane-deletion-log-$(date -u -d '-50 days' +%Y%m%dT%H%M%SZ).csv"; cp "$F1" "$OLD"; ( cd "$XD" && md5sum "$(basename "$OLD")" > "$(basename "$OLD").md5" )
sleep 1.2; rc=$(x x4.out); n=$(ls -1 "$XD"/*.csv | wc -l)
check "X4 changed list -> new file; a 50-day-old file is pruned (45 days), the previous one stays" "$rc|$n|$([[ -e "$OLD" || -e "$OLD.md5" ]] && echo old-left || echo old-gone)|$(grep -c 'pruned 1 file' "$OUT/x4.out")" "0|2|old-gone|1"
P -d dl_main -c "delete from kodhane_private.deletion_log where approval_ref = 'info:X3'" >/dev/null
F4=$(ls -1 "$XD"/*.csv | tail -n1); [[ "$F4" != "$F1" ]] && rm -f "$F4" "$F4.md5"   # back to the first export only (the X3 row was test-only)
rc=$(XDB=dl_nolog x x5.out)
check "X5 database without the migration -> STOP, no file" "$rc|$(grep -c 'deletion_log does not exist' "$OUT/x5.out")|$(ls -1 "$XD"/*.csv | wc -l)" "1|1|1"
P -d postgres -c "drop database if exists dl_fen with (force)" -c "create database dl_fen template dl_main" >/dev/null 2>&1; P -d dl_fen -c "create table public.fenomen_saves (user_id uuid)" >/dev/null
rc=$(XDB=dl_fen x x6.out)
check "X6 wrong target (fenomen_saves present) -> STOP, no file" "$rc|$(grep -c 'wrong target' "$OUT/x6.out")|$(ls -1 "$XD"/*.csv | wc -l)" "1|1|1"
chmod 755 "$XD"; rc=$(x x7.out); chmod 700 "$XD"
check "X7 the export resets the directory to 700" "$rc|$(stat -c %a "$XD")" "0|700"

# ------------------------------------------------------------------ R: restore (pre-deletion backup) + reapply + verify
dumpfc dl_main "$OUT/post.dump"   # after the deletions (R7)
P -d dl_main -c "insert into kodhane_private.deletion_log (user_id, scope, approval_ref) select '$U4', 'account', 'info:R0-not-exported' where false" >/dev/null
R() { KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=$1 KODHANE_OUT=$OUT/$2 KODHANE_DL_DIR="$XD" KODHANE_RESTORE_CONFIRM=$(basename "$3") bash "$B" restore "$3" > "$OUT/$2.out" 2>&1; echo $?; }
rc=$(R dl_main r1 "$OUT/pre.dump")
check "R1 kodhane_v44b_install.sh restore <pre-deletion backup>: export from the current DB (unchanged) -> restore -> reapply -> verify" \
  "$rc|$(grep -c 'unchanged (2 row' "$OUT/r1.out")|$(grep -oE '^(RESTORE\|PASS|REAPPLY\|PASS|VERIFY\|PASS\|0 left|RESTORE\|DELETION_LOG\|PASS)$' "$OUT/r1.out" | tr '\n' ' ')" \
  "0|1|RESTORE|PASS REAPPLY|PASS VERIFY|PASS|0 left RESTORE|DELETION_LOG|PASS "
check "R1b reapply summary: account 1 deleted again, kodhane 1 deleted again, 2 list rows re-added" "$(grep -E '^REAPPLY\|file_rows' "$OUT/r1.out" | cut -d'|' -f2-)" \
  "file_rows|2|entries|2|list_rows_added|2|list_rows_missing_before|2|account|1|audit|0|orphan|0|kodhane|1|newer|0|mixed|0|nothing|0"
check "R2 list after restore + reapply: both rows with the original time and reference" \
  "$(dl_rows dl_main)|$(PA -d dl_main -c "select string_agg(to_char(deleted_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), ',' order by user_id) from kodhane_private.deletion_log")" \
  "11111111/account/info:TEST-ONAY-1 33333333/kodhane/info:TEST-ONAY-3|$(tail -n +2 "$F1" | sort | cut -d, -f3 | paste -sd,)"
check "R3 u1: no row anywhere (auth, both games, audit)" "$(user_n dl_main $U1)" ""
check "R3b u3: no Kodhane row, sessions closed; kept: auth user, profile, Açık Ofis, audit" "$(user_n dl_main $U3)" "auth.audit_log_entries=1 auth.users=1 public.acik_ofis_profiles=1 public.acik_ofis_saves=1 public.kodhane_profiles=1"
check "R3c u3 kept rows identical to before the deletion" "$(PA -d dl_main -c "select rel || '=' || h from t.snap_of('$U3')")" "$U3K0"
check "R4 other users (u2, u4, every table incl. progress log and audit) identical to before the deletions" "$(fp dl_main "$U1,$U3,$U4" | md5sum | cut -c1-12)/$(fp dl_main "$U1,$U3,$U4" | wc -l)" "$(echo "$FP0" | md5sum | cut -c1-12)/$(echo "$FP0" | wc -l)"
check "R4b u4 (not listed) untouched: Kodhane save, backups, profile, auth" "$(user_n dl_main $U4)" "auth.audit_log_entries=1 auth.users=1 public.kodhane_profiles=1 public.kodhane_progress_log=$(PA -d dl_main -c "select count(*) from public.kodhane_progress_log where user_id = '$U4'") public.kodhane_save_backups=1 public.kodhane_saves=1"
m0=$(data_md5 dl_main)
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/r5 KODHANE_DL_DIR="$XD" bash "$REA" reapply > "$OUT/r5.out" 2>&1; rc=$?
check "R5 second reapply: nothing to do, data identical (pg_dump --data-only md5)" "$rc|$(grep -E '^REAPPLY\|file_rows' "$OUT/r5.out" | cut -d'|' -f6-7,10-)|$(data_md5 dl_main)" \
  "0|list_rows_added|0|account|0|audit|0|orphan|0|kodhane|0|newer|0|mixed|0|nothing|2|$m0"
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/r5 KODHANE_DL_DIR="$XD" bash "$REA" verify > "$OUT/r5v.out" 2>&1; rc=$?
check "R5b verify: 0 left" "$rc|$(tail -n1 "$OUT/r5v.out")" "0|VERIFY|PASS|0 left"
o=$(KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/ins bash "$INS" verify | tail -n1)
check "R6 install checks after the restore (ACLs, RLS, owner as installed)" "$o" "VERIFY|PASS"
python3 - "$OUT/r1/deletion_log_reapply.sql" "$DEL" "$PRE" "$VER" <<'PY' && pass "R6b reapply SQL carries the delete's DO block verbatim and the same <kodhane_del_counts> block as preflight / delete / verify" || fail "R6b blocks differ"
import re, sys
g, d = open(sys.argv[1]).read(), open(sys.argv[2]).read()
body = d.split('\ndo $del$\n', 1)[1].split('\nend $del$;\n', 1)[0]
blocks = [b for f in sys.argv[1:] for b in re.findall(r'-- <kodhane_del_counts>.*?-- </kodhane_del_counts>', open(f).read(), re.S)]
sys.exit(0 if body in g and len(blocks) == 4 + 3 + 2 + 2 and len(set(blocks)) == 1 else 1)
PY
P -d postgres -c "drop database if exists dl_post with (force)" -c "create database dl_post template $BASE" >/dev/null 2>&1
docker exec -i "$CT" pg_restore -U supabase_admin -d dl_post < "$OUT/post.dump" > "$OUT/r7restore.log" 2>&1
m1=$(data_md5 dl_post)
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_post KODHANE_OUT=$OUT/r7 KODHANE_DL_DIR="$XD" bash "$REA" reapply > "$OUT/r7.out" 2>&1; rc=$?
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_post KODHANE_OUT=$OUT/r7 KODHANE_DL_DIR="$XD" bash "$REA" verify > "$OUT/r7v.out" 2>&1; rv=$?
check "R7 backup taken AFTER the deletions (pg_restore into a new DB): reapply is a no-op, verify 0" "$rc$rv|$(data_md5 dl_post)|$(tail -n1 "$OUT/r7v.out")" "00|$m1|VERIFY|PASS|0 left"
# R8: a deletion after the last export: the restore's step 0 recovers it from the current DB
del dl_main r8d.log full $U4 TEST-ONAY-4 || fail "R8 setup delete u4: $(grep -m1 ERROR "$OUT/r8d.log")"
nf0=$(ls -1 "$XD"/*.csv | wc -l)
rc=$(R dl_main r8 "$OUT/pre.dump")
check "R8 deletion after the last export (u4): restore step 0 writes a new export from the current DB, reapply deletes u1, u3, u4" \
  "$rc|$(( $(ls -1 "$XD"/*.csv | wc -l) - nf0 ))|$(grep -E '^REAPPLY\|file_rows' "$OUT/r8.out" | cut -d'|' -f2-5,10-13,16-17)|$(tail -n1 "$OUT/r8.out")" \
  "0|1|file_rows|5|entries|3|account|2|audit|0|kodhane|1|RESTORE|DELETION_LOG|PASS"
check "R8b u4 gone again, u1 gone, u2 untouched" "$(user_n dl_main $U4)|$(user_n dl_main $U1)|$(fp dl_main "$U1,$U3,$U4" | md5sum | cut -c1-12)" "||$(echo "$FP0" | md5sum | cut -c1-12)"
s0=$(data_md5 dl_main)
rc=$(KODHANE_DL_DIR=/proc/dl-test-unwritable R dl_main r9 "$OUT/pre.dump")
rc=$(KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/r9 KODHANE_DL_DIR=/proc/dl-test-unwritable KODHANE_RESTORE_CONFIRM=pre.dump bash "$B" restore "$OUT/pre.dump" > "$OUT/r9.out" 2>&1; echo $?)
check "R9 export before the restore fails (directory not writable) -> STOP before the restore, DB unchanged" "$rc|$(grep -c 'deletion log export from the current DB failed' "$OUT/r9.out")|$(data_md5 dl_main)" "1|1|$s0"

# ------------------------------------------------------------------ K: scope kodhane after a restore: played again / mixed; audit; block
P -d dl_main -c "select t.login('$U3')" -c "select t.kpush(t.ksave(1234, 1))" -c "select t.logout()" >/dev/null
dumpfc dl_main "$OUT/late.dump"   # u3 plays again after the kodhane_only deletion; backup after that
rc=$(R dl_main k1 "$OUT/late.dump")
check "K1 restore of a backup with u3's NEW save (after the deletion): reapply keeps it (newer), verify 0" \
  "$rc|$(grep -E '^ENTRY\|33333333' "$OUT/k1.out" | cut -d'|' -f3-4 | head -n1)|$(PA -d dl_main -c "select count(*) from public.kodhane_saves where user_id = '$U3'")|$(tail -n1 "$OUT/k1.out")" \
  "0|kodhane|newer|1|RESTORE|DELETION_LOG|PASS"
P -d dl_main -c "update public.kodhane_saves set revision = revision + 1, updated_at = (select deleted_at - interval '1 day' from kodhane_private.deletion_log where user_id = '$U3' and scope = 'kodhane') where user_id = '$U3'" >/dev/null
P -d dl_main -c "insert into public.kodhane_save_backups (user_id, revision, payload, best_score, best_stage, reason, created_at) values ('$U3', 1, '{}', 0, 0, 'manual', now())" >/dev/null 2>&1 \
  || P -d dl_main -c "insert into public.kodhane_save_backups (user_id, revision, payload, reason) values ('$U3', 1, '{}', 'manual')" >/dev/null
k0=$(user_n dl_main $U3)
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/k2 KODHANE_DL_DIR="$XD" bash "$REA" reapply > "$OUT/k2.out" 2>&1; rc=$?
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/k2 KODHANE_DL_DIR="$XD" bash "$REA" verify > "$OUT/k2v.out" 2>&1; rv=$?
check "K2 u3 with Kodhane rows from before AND after the deletion: reapply exit 3 (committed, MIXED, not deleted), verify FAIL" \
  "$rc/$rv|$(grep -cE '^ENTRY\|33333333[^|]*\|kodhane\|mixed\|MIXED' "$OUT/k2.out")|$([[ "$(user_n dl_main $U3)" == "$k0" ]] && echo kept)|$(grep -c '^VERIFY|FAIL' "$OUT/k2v.out")" "3/1|1|kept|1"
P -d dl_main -c "delete from public.kodhane_save_backups where user_id = '$U3'" -c "delete from public.kodhane_saves where user_id = '$U3'" >/dev/null
P -d dl_main -c "insert into auth.audit_log_entries (instance_id, id, payload, created_at) values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), json_build_object('action', 'login', 'actor_id', '$U1'), now())" >/dev/null
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/k3 KODHANE_DL_DIR="$XD" bash "$REA" verify > "$OUT/k3v.out" 2>&1; rv=$?
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_main KODHANE_OUT=$OUT/k3 KODHANE_DL_DIR="$XD" bash "$REA" reapply > "$OUT/k3.out" 2>&1; rc=$?
check "K3 listed account without auth user but with an audit row: verify FAIL (audit), reapply deletes it, 0 left" \
  "$rv/$rc|$(grep -cE '^ENTRY\|11111111[^|]*\|account\|audit\|LEFT' "$OUT/k3v.out")|$(user_n dl_main $U1)|$(tail -n1 "$OUT/k3.out")" "1/0|1||REAPPLY|PASS"
P -d postgres -c "drop database if exists dl_blk with (force)" >/dev/null 2>&1
P -d postgres -c "create database dl_blk template $BASE" >/dev/null 2>&1; docker exec -i "$CT" pg_restore -U supabase_admin -d dl_blk < "$OUT/pre.dump" > /dev/null 2>&1
P -d dl_blk -c "create table public.zz_other (user_id uuid references auth.users (id) on delete cascade)" -c "insert into public.zz_other values ('$U1')" >/dev/null
b0=$(data_md5 dl_blk)
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_blk KODHANE_OUT=$OUT/k4 KODHANE_DL_DIR="$XD" bash "$REA" reapply > "$OUT/k4.out" 2>&1; rc=$?
check "K4 a row outside Kodhane / Açık Ofis (FK to auth.users) -> BLOCKED, whole reapply rolled back (list rows too)" \
  "$rc|$(grep -c 'BLOCKED: rows outside Kodhane' "$OUT/k4.out")|$(data_md5 dl_blk)" "1|1|$b0"

# ------------------------------------------------------------------ F: bad files are refused (nothing runs)
P -d postgres -c "drop database if exists dl_f with (force)" -c "create database dl_f template $BASE" >/dev/null 2>&1; docker exec -i "$CT" pg_restore -U supabase_admin -d dl_f < "$OUT/pre.dump" > /dev/null 2>&1
f0=$(data_md5 dl_f); FD="$OUT/fbad"
fcase() {  # fcase <name> <expected BAD regex> : builds $FD from the good first export, applies $FMOD, runs reapply
  local name=$1 re=$2; rm -rf "$FD"; mkdir -p "$FD"; chmod 700 "$FD"; cp "$F1" "$F1.md5" "$FD/"; local f="$FD/$(basename "$F1")"
  eval "$FMOD"
  local o="$OUT/${name%% *}.out"
  KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_f KODHANE_OUT=$OUT/f KODHANE_DL_DIR="$FD" bash "$REA" reapply > "$o" 2>&1; local rc=$?
  if [[ $rc == 1 ]] && grep -qE "$re" "$o" && [[ "$(data_md5 dl_f)" == "$f0" ]]; then pass "$name  -- $(grep -m1 -oE 'BAD\|.*|ERROR: .*' "$o" | cut -c1-110); nothing changed"
  else fail "$name rc $rc: $(head -c 400 "$o")"; fi
}
remd5() { ( cd "$(dirname "$1")" && md5sum "$(basename "$1")" > "$(basename "$1").md5" ); }
FMOD='sed -i "s/TEST-ONAY-1/TEST-ONAY-9/" "$f"'; fcase "F1 one character changed, old .md5 -> md5 mismatch" 'md5 does not match'
FMOD='truncate -s -20 "$f"; remd5 "$f"'; fcase "F2 truncated file (new .md5) -> malformed / no final newline" 'BAD\|.*(no final newline|malformed row)'
FMOD='sed -i "1s/.*/user_id,deleted_at_utc,approval_ref/" "$f"; remd5 "$f"'; fcase "F3 wrong header (new .md5)" 'header is not'
FMOD='sed -i "2s/info:TEST-ONAY-1/info:a@example.invalid/" "$f"; remd5 "$f"'; fcase "F4 e-mail in a row (new .md5)" 'line 2: malformed row'
FMOD='rm -f "$f.md5"'; fcase "F5 .md5 missing" 'no .md5 file'
FMOD='mv "$f" "$FD/liste.csv"; mv "$f.md5" "$FD/liste.csv.md5"'; FMODX=1
rm -rf "$FD"; mkdir -p "$FD"; cp "$F1" "$FD/liste.csv"; ( cd "$FD" && md5sum liste.csv > liste.csv.md5 )
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_f KODHANE_OUT=$OUT/f bash "$REA" reapply "$FD/liste.csv" > "$OUT/f6.out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q 'unexpected file name' "$OUT/f6.out" && [[ "$(data_md5 dl_f)" == "$f0" ]] && pass "F6 unexpected file name (given explicitly) -> refused, nothing changed" || fail "F6 rc $rc"
FMOD='G="$FD/kodhane-deletion-log-20261003T000000Z.csv"; printf "user_id,scope,deleted_at_utc,approval_ref\nnot-a-uuid,account,x,info:y\n" > "$G"; remd5 "$G"'
fcase "F7 one bad file among good ones -> the whole run refused" 'kodhane-deletion-log-20261003T000000Z.csv line 2: malformed row'
FMOD='printf "%s\n" "$U2,account,2099-01-01T00:00:00.000000Z,info:future" >> "$f"; remd5 "$f"'; fcase "F8 well-formed row with a future time (new .md5) -> SQL check refuses, rolled back" 'invalid file rows'
rm -rf "$FD"; mkdir -p "$FD"
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_f KODHANE_OUT=$OUT/f KODHANE_DL_DIR="$FD" bash "$REA" reapply > "$OUT/f9.out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q 'no export files' "$OUT/f9.out" && pass "F9 no export files -> STOP" || fail "F9 rc $rc"
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_f KODHANE_OUT=$OUT/f KODHANE_DL_DIR="$XD" bash "$REA" dryrun > "$OUT/f10.out" 2>&1; rc=$?
check "F10 dry run on the restored backup: would delete u1 + u3 + u4, ROLLBACK, data unchanged" "$rc|$(grep -E '^REAPPLY\|file_rows' "$OUT/f10.out" | cut -d'|' -f10-17)|$(data_md5 dl_f)" "0|account|2|audit|0|orphan|0|kodhane|1|$f0"
P -d dl_nolog -c "select 1" >/dev/null
KODHANE_TARGET=local KODHANE_CT=$CT KODHANE_DB=dl_nolog KODHANE_OUT=$OUT/f KODHANE_DL_DIR="$XD" bash "$REA" reapply > "$OUT/f11.out" 2>&1; rc=$?
check "F11 restored DB without the migration (backup older than the install) -> STOP: install the migration first" "$rc|$(grep -c 'install migration 20261003040000 first' "$OUT/f11.out")" "1|1"

# ------------------------------------------------------------------ T: retention
P -d dl_main -c "insert into kodhane_private.deletion_log (user_id, scope, deleted_at, approval_ref) values (gen_random_uuid(), 'account', now() - interval '46 days', 'info:T1-old'), (gen_random_uuid(), 'kodhane', now() - interval '44 days', 'info:T1-keep')" >/dev/null
r=$(PG -d dl_main -c "select kodhane_private.cleanup_deletion_log()")
check "T1 cleanup as postgres: the 46-day row goes, the 44-day row stays (45 days)" "$r|$(PA -d dl_main -c "select string_agg(approval_ref, ',') from kodhane_private.deletion_log where approval_ref like 'info:T1%'")" "1|info:T1-keep"
r=$(P -d dl_main -c "set role service_role" -c "select kodhane_private.cleanup_deletion_log()" 2>&1 | grep -c 'permission denied')
check "T2 service_role cannot run the cleanup" "$r" "1"
C0="$OPS/kodhane_retention_dokploy_command.txt"; CL="$OPS/kodhane_retention_dokploy_command_with_progress_log.txt"
CD="$OPS/kodhane_retention_dokploy_command_with_deletion_log.txt"; CLD="$OPS/kodhane_retention_dokploy_command_with_progress_log_and_deletion_log.txt"
STEP=' -c "select kodhane_private.cleanup_deletion_log() as deletion_log_rows"'
check "T3 Dokploy variants: one line each, = existing command + the cleanup step at the end" "$(cat "$CD" "$CLD" | wc -l)|$([[ "$(cat "$CD")" == "$(cat "$C0")$STEP" && "$(cat "$CLD")" == "$(cat "$CL")$STEP" ]] && echo prefix-ok)" "2|prefix-ok"
if grep -q "['\$\`\\\\]" "$CD" "$CLD"; then fail "T3b quote / dollar / backtick / backslash in a variant"; else pass "T3b no single quote, dollar, backtick or backslash (safe in sh -c '...')"; fi
RB="$ROOT/../docs/kodhane-retention-runbook.md"
grep -qxF "$(cat "$CD")" "$RB" && grep -qxF "$(cat "$CLD")" "$RB" && pass "T3c retention runbook contains both variants verbatim" || fail "T3c runbook"
P -d template1 -c "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'postgres' and pid <> pg_backend_pid()" \
  -c "alter database postgres rename to dl_postgres_orig" -c "create database postgres template $BASE" >/dev/null
P -d postgres -f - < "$MIGR" >/dev/null 2>&1 && P -d postgres -f - < "$MIGL" >/dev/null 2>&1 || fail "T4 setup (retention + progress log migrations)"
dok() { sh -c "docker exec $CT sh -c '$(cat "$2")'" > "$OUT/$1" 2>&1; echo $?; }
rc=$(dok t4a.out "$CLD")
check "T4 deletion log not installed: variant fails at the LAST step (exit 1), earlier steps ran" "$rc|$(grep -c 'kodhane_private.cleanup_deletion_log() does not exist\|schema \"kodhane_private\" does not exist' "$OUT/t4a.out")|$(grep -c 'progress_log_left_over_365d' "$OUT/t4a.out")" "1|1|1"
P -d postgres -f - < "$MIGD" >/dev/null 2>&1 || fail "T5 setup"
P -d postgres -c "insert into kodhane_private.deletion_log (user_id, scope, deleted_at, approval_ref) values (gen_random_uuid(), 'account', now() - interval '50 days', 'info:T5'), (gen_random_uuid(), 'account', now() - interval '47 days', 'info:T5'), (gen_random_uuid(), 'account', now(), 'info:T5-keep')" >/dev/null
rc=$(dok t5.out "$CLD"); r1=$(grep -E '^deletion_log_rows' "$OUT/t5.out" | tr -s ' ')
rc2=$(dok t5b.out "$CD"); r2=$(grep -E '^deletion_log_rows' "$OUT/t5b.out" | tr -s ' ')
check "T5 Dokploy variants as root -> psql -U postgres: 2 old rows deleted, then 0; exit 0" "$rc|$r1|$rc2|$r2|$(PA -d postgres -c "select count(*) from kodhane_private.deletion_log")" "0|deletion_log_rows | 2|0|deletion_log_rows | 0|1"
P -d postgres -c "insert into kodhane_private.deletion_log (user_id, scope, deleted_at, approval_ref) values (gen_random_uuid(), 'kodhane', now() - interval '60 days', 'info:T6')" >/dev/null
o=$(docker exec -i "$CT" sh -s < "$OPS/kodhane_retention_daily.sh" 2>&1); rc=$?
check "T6 daily script step 5: deletion log cleanup" "$rc|$(sed -nE 's/^[0-9TZ:-]+ (kodhane retention deletion log .*)/\1/p' <<<"$o")" "0|kodhane retention deletion log OK: deletion_log 1 row(s) older than 45 days deleted"
P -d postgres -f - < "$RBD" -c "select 1" >/dev/null 2>&1; PGOPTIONS='-c kodhane.deletion_log_allow_loss=on' true
docker exec -i -e PGOPTIONS='-c kodhane.deletion_log_allow_loss=on' "$CT" psql -U supabase_admin -X -q -d postgres -f - < "$RBD" >/dev/null 2>&1
o=$(docker exec -i "$CT" sh -s < "$OPS/kodhane_retention_daily.sh" 2>&1); rc=$?
check "T6b daily script without the deletion log: step 5 skipped, exit 0" "$rc|$(sed -nE 's/^[0-9TZ:-]+ (kodhane retention deletion log .*)/\1/p' <<<"$o")" "0|kodhane retention deletion log skipped: migration 20261003040000 not applied in database postgres"
P -d template1 -c "drop database postgres with (force)" -c "alter database dl_postgres_orig rename to postgres" >/dev/null
check "T7 container's own postgres database restored" "$(PA -d postgres -c "select to_regclass('public.kodhane_saves') is null")" t

for d in dl_main dl_nolog dl_fen dl_post dl_blk dl_f; do P -d postgres -c "drop database if exists $d with (force)" >/dev/null 2>&1; done
echo "== done: $PASSN pass / $FAILS fail ($(for k in "${!NT[@]}"; do printf '%s %s, ' "$k" "${NT[$k]}"; done | sed 's/, $//')); image $(docker inspect -f '{{.Config.Image}}' "$CT"); artefacts in $OUT"
[[ $FAILS == 0 ]]
