#!/usr/bin/env bash
# Kodhane manual account deletion (ops/kodhane_account_delete_*.sql, mode=full | kodhane_only) tests.
# LOCAL THROWAWAY DATABASES ONLY, in the local docker container $KD_CT (supabase/postgres image) whose database $KD_BASE
# holds the live schema after v2.2 (no data). Never point this at the live DB: it drops/creates databases and deletes rows.
# Runs the whole suite twice: on the base schema and on base + package A + package B (v4.4); then L-* (variant abl):
# base + A + B + progress log (migration 20261003020000): the user's log rows go in both modes.
#   KD_CT=<container> bash supabase/tests/account_delete/run_kodhane_account_delete_tests.sh 2>&1 | tee /tmp/kd-del-test.log
# Test names: C-* = common (mode checks, preflight, triggers), F-* = mode=full, K-* = mode=kodhane_only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CT="${KD_CT:-v44db136}"; BASE="${KD_BASE:-v44_base}"; OUT="${KD_OUT:-/tmp/kd-del-test}"; mkdir -p "$OUT"; chmod 700 "$OUT"
PRE="$ROOT/ops/kodhane_account_delete_preflight.sql"; DEL="$ROOT/ops/kodhane_account_delete.sql"; VER="$ROOT/ops/kodhane_account_delete_verify.sql"
MIGL="$ROOT/migrations/20261003020000_v4_4_kodhane_progress_log.sql"
MIGA="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"; MIGB="$ROOT/migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql"
U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222; U3=33333333-3333-4333-8333-333333333333
U4=44444444-4444-4444-8444-444444444444; U5=55555555-5555-4555-8555-555555555555; NOBODY=99999999-9999-4999-8999-999999999999
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
PA() { P -At -F '|' "$@"; }
FAILS=0; PASSN=0; declare -A NT=([C]=0 [F]=0 [K]=0 [L]=0)
V=""   # current variant label
pass() { echo "PASS [$V] $*"; PASSN=$((PASSN+1)); local k=${1:0:1}; NT[$k]=$(( ${NT[$k]:-0} + 1 )); }
fail() { echo "FAIL [$V] $*"; FAILS=$((FAILS+1)); }
ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
fresh() { P -d postgres -c "drop database if exists $1" -c "create database $1 template $BASE" >/dev/null 2>&1; }
seed() { P -d "$1" -f - < "$ROOT/tests/fixtures/helpers.sql" >/dev/null && P -d "$1" -f - < "$HERE/seed.sql" >/dev/null && P -d "$1" -f - < "$HERE/snap.sql" >/dev/null; }
preflight() { PA -d "$1" -v uid="$2" -f - < "$PRE" 2>&1; }
token() { preflight "$1" "$2" | grep -E '^(OK|BLOCKED|STOP):' | awk -F'|' '{print $NF}'; }
n_of() { awk -F'|' -v r="$2" 'NF == 6 && $2 == r {print $4}' "$1"; }
del() { local db=$1 log=$2; shift 2; P -d "$db" "$@" -f - < "$DEL" > "$OUT/$V.$log" 2>&1; }
verify() { local db=$1 log=$2; shift 2; P -d "$db" "$@" -f - < "$VER" > "$OUT/$V.$log" 2>&1; }
snap() { PA -d "$1" -c "select * from t.snap(${2:+'$2'})"; }
snap_of() { PA -d "$1" -c "select * from t.snap_of('$2')"; }
ao() { PA -d "$1" -c "select * from t.ao_state()"; }
lb() { PA -d "$1" -c "select * from t.lb()"; }
lb_as() { PA -d "$1" -c "select t.login('$2')" -c "select l::text from public.kodhane_leaderboard(100) l" | sed '/^$/d'; }
lb7_as() { PA -d "$1" -c "select t.login('$2')" -c "select l::text from public.kodhane_leaderboard_v7(100) l" | sed '/^$/d'; }
lbao() { PA -d "$1" -c "select * from t.lb_ao()"; }
lb7() { PA -d "$1" -c "select * from t.lb7()"; }
dump() { docker exec "$CT" pg_dump -U supabase_admin --schema-only -n public -n auth "$1" | grep -v '^\\\(un\)\?restrict '; }
err() { grep -m1 -oE 'ERROR: .*' "$OUT/$V.$1" | cut -c1-170; }
refused() {   # refused <name> <db> <log> <expected message regex> <snapshot file> [psql -v args...]
  local name=$1 db=$2 log=$3 re=$4 before=$5; shift 5
  if del "$db" "$log" "$@"; then fail "$name: delete ran (exit 0)"; return; fi
  if ! grep -qE "$re" "$OUT/$V.$log"; then fail "$name: wrong error: $(err "$log")"; return; fi
  snap "$db" > "$OUT/$V.$log.snap"
  if diff -q "$before" "$OUT/$V.$log.snap" >/dev/null; then pass "$name  -- $(err "$log"); nothing changed"
  else fail "$name: data changed, see $OUT/$V.$log.snap"; fi
}
boom() { P -d "$1" -c "create or replace function t.boom() returns trigger language plpgsql as \$\$ begin raise exception 'kd test: injected failure in %', tg_table_name; end \$\$" -c "$2" >/dev/null; }
unboom() { P -d "$1" -c "drop trigger kd_test_boom on $2" >/dev/null; }
echo "== image: $(docker inspect "$CT" --format '{{.Config.Image}}'); base: $BASE"

V=files
python3 - "$PRE" "$DEL" "$VER" <<'PY' && pass "C-T0 counts query byte-identical in preflight (2) / delete (3) / verify (2); identity part of the token identical in preflight / delete" || fail "C-T0 counts query or identity block differs"
import re, sys
txt = [open(f).read() for f in sys.argv[1:]]
blocks = [b for t in txt for b in re.findall(r'-- <kodhane_del_counts>.*?-- </kodhane_del_counts>', t, re.S)]
ident = [b for t in txt for b in re.findall(r'-- <kodhane_del_identity>.*?-- </kodhane_del_identity>', t, re.S)]
sys.exit(0 if len(blocks) == 7 and len(set(blocks)) == 1 and len(ident) == 2 and len(set(ident)) == 1 else 1)
PY
grep -qiE '^\s*(insert|update|delete|truncate|create|alter|drop)\b' "$PRE" "$VER" && fail "C-T0b preflight/verify contain a write statement" || pass "C-T0b preflight / verify: read only transaction, no write statement"

suite() {   # suite <db> <variant: base | ab>
  local D=$1; V=$2
  echo "== [$V] setup"
  fresh $D
  if [[ $V == ab ]]; then P -d $D -1 -f - < "$MIGA" >/dev/null 2>&1 && P -d $D -1 -f - < "$MIGB" >/dev/null 2>&1 || { fail "C-setup A+B"; return; }; fi
  seed $D || { fail "C-setup seed"; return; }
  snap $D > "$OUT/$V.s0.snap"; dump $D > "$OUT/$V.dump0.sql"
  local OLDK1 OLDA1 OLDK3 T1 T3 T4 T
  OLDK1=$(PA -d $D -c "select id from public.kodhane_save_backups where user_id = '$U1'"); OLDA1=$(PA -d $D -c "select id from public.acik_ofis_save_backups where user_id = '$U1'")
  OLDK3=$(PA -d $D -c "select id from public.kodhane_save_backups where user_id = '$U3'")

  echo "== [$V] preflight"
  preflight $D $U1 > "$OUT/$V.pre_u1.txt"; local f="$OUT/$V.pre_u1.txt" got
  got="kodhane: saves=$(n_of $f public.kodhane_saves) backups=$(n_of $f public.kodhane_save_backups) profiles=$(n_of $f public.kodhane_profiles); acik_ofis: saves=$(n_of $f public.acik_ofis_saves) backups=$(n_of $f public.acik_ofis_save_backups) profiles=$(n_of $f public.acik_ofis_profiles); audit=$(n_of $f auth.audit_log_entries); auth: users=$(n_of $f auth.users) identities=$(n_of $f auth.identities) sessions=$(n_of $f auth.sessions) refresh_tokens=$(n_of $f auth.refresh_tokens) flow_state=$(n_of $f auth.flow_state) one_time_tokens=$(n_of $f auth.one_time_tokens) mfa_factors=$(n_of $f auth.mfa_factors)"
  [[ "$got" == "kodhane: saves=1 backups=1 profiles=1; acik_ofis: saves=1 backups=1 profiles=1; audit=3; auth: users=1 identities=1 sessions=1 refresh_tokens=2 flow_state=1 one_time_tokens=1 mfa_factors=1" ]] \
    && pass "C-P1 preflight lists both games separately + auth + audit  -- $got" || fail "C-P1 counts: $got"
  grep -q '^kodhane|reset|1|' $f && grep -q '^acik_ofis|manual|1|' $f && grep -q '^kodhane|500000000|3|t|f|t$' $f && grep -q '^acik_ofis|70000|' $f \
    && pass "C-P2 preflight: backups by reason and leaderboard state per game" || fail "C-P2 per-game sections"
  grep -qE '^OK: deletes Kodhane 3 \+ Açık Ofis 3 \+ audit 3 rows \+ the auth user\|OK: deletes 2 Kodhane rows \(saves, backups, progress log, carry\) \+ closes 3 sessions / refresh tokens; .*\|[0-9a-f]{12}$' $f \
    && pass "C-P3 preflight verdict for both modes + expect token" || fail "C-P3 verdict: $(grep -E '^(OK|BLOCKED|STOP)' $f)"
  grep -q 'u\*\*\*@example.invalid' $f && ! grep -qE 'u1-v22-test@|Silinecek' $f && pass "C-P4 e-mail masked, no nickname in the preflight" || fail "C-P4 personal data in the preflight"
  T1=$(token $D $U1); T3=$(token $D $U3); T4=$(token $D $U4)
  P -d $D -c "insert into public.acik_ofis_save_backups (user_id, revision, payload, reason) values ('$U1', 9, '{}', 'manual')" >/dev/null; T=$(token $D $U1)
  P -d $D -c "delete from public.acik_ofis_save_backups where user_id = '$U1' and revision = 9" >/dev/null
  [[ $T != "$T1" && $(token $D $U1) == "$T1" ]] && pass "C-P5 expect token covers Açık Ofis rows too (one extra AO backup changes it)" || fail "C-P5 token $T1 / $T"
  snap $D > "$OUT/$V.s0b.snap"; diff -q "$OUT/$V.s0.snap" "$OUT/$V.s0b.snap" >/dev/null && pass "C-P6 preflight changes nothing" || fail "C-P6 preflight changed data"

  echo "== [$V] triggers"
  local r
  r=$(PA -d $D -c "begin" -c "delete from public.kodhane_saves where user_id = '$U1'" -c "delete from public.acik_ofis_saves where user_id = '$U1'" \
    -c "select (select count(*) || '/' || max(best_score) from public.kodhane_save_backups where user_id = '$U1' and reason = 'delete') || ' ' || (select count(*) || '/' || max(best_score) from public.acik_ofis_save_backups where user_id = '$U1' and reason = 'delete')" -c "rollback")
  [[ "$r" == "1/500000000 1/70000" ]] && pass "C-D1 both delete triggers write a 'delete' copy with the best score (Kodhane, Açık Ofis)  -- $r" || fail "C-D1 got $r"
  r=$(PA -d $D -c "begin" -c "delete from public.kodhane_saves where user_id = '$U1'" -c "delete from public.kodhane_save_backups where user_id = '$U1' and reason <> 'delete'" \
    -c "insert into public.kodhane_saves (user_id, data, save_version) values ('$U1', t.ksave(450000000), 4) returning best_score" -c "rollback")
  [[ "$r" == 500000000 ]] && pass "C-D2 control: if the 'delete' copy stayed, a re-created row would start at the old best score (5e8)" || fail "C-D2 got $r"

  echo "== [$V] mode checks (nothing may change)"
  refused "C-M1 no mode, user with Açık Ofis rows -> BLOCKED" $D m1.log 'BLOCKED: mode missing .*Non-Kodhane rows: public.acik_ofis_profiles=1, public.acik_ofis_save_backups=1, public.acik_ofis_saves=1' "$OUT/$V.s0.snap" -v uid=$U1 -v confirm_uid=$U1 -v approval_ref=TEST-1 -v expect=$T1
  refused "C-M2 no mode, Kodhane-only user -> refused" $D m2.log 'BLOCKED: mode missing \(-v mode=full \| kodhane_only\); nothing deleted$' "$OUT/$V.s0.snap" -v uid=$U4 -v confirm_uid=$U4 -v approval_ref=TEST-1 -v expect=$T4
  refused "C-M3 mode='' -> refused" $D m3.log 'mode missing' "$OUT/$V.s0.snap" -v mode= -v uid=$U1 -v confirm_uid=$U1 -v approval_ref=TEST-1 -v expect=$T1
  refused "C-M4 unknown mode -> refused" $D m4.log 'unknown mode "everything"' "$OUT/$V.s0.snap" -v mode=everything -v uid=$U1 -v confirm_uid=$U1 -v approval_ref=TEST-1 -v expect=$T1
  refused "C-M5 mode=KODHANE (typo, no underscore) -> refused" $D m5.log 'unknown mode "kodhane"' "$OUT/$V.s0.snap" -v mode=KODHANE -v uid=$U3 -v confirm_uid=$U3 -v approval_ref=TEST-1 -v expect=$T3
  verify $D vm1.log -v uid=$U1 && fail "C-M6 verify without mode passed" || { grep -q 'mode missing' "$OUT/$V.vm1.log" && pass "C-M6 verify without mode -> error" || fail "C-M6 wrong error"; }
  verify $D vm2.log -v mode=bogus -v uid=$U1 && fail "C-M7 verify with unknown mode passed" || { grep -q 'unknown mode "bogus"' "$OUT/$V.vm2.log" && pass "C-M7 verify with unknown mode -> error" || fail "C-M7 wrong error: $(err vm2.log)"; }

  local U6=66666666-6666-4666-8666-666666666666 U7=77777777-7777-4777-8777-777777777777 T6 T7
  P -d $D -c "insert into auth.users (id, email, created_at) values ('$U6', null, '2026-01-01 00:00:00+00'), ('$U7', null, '2026-01-01 00:00:00+00')" >/dev/null
  T6=$(token $D $U6); T7=$(token $D $U7); snap $D > "$OUT/$V.s0i.snap"
  if [[ -n $T6 && $T6 != "$T7" ]]; then
    refused "C-E3 token of another user with identical rows, e-mail and created_at (only the id differs) -> refused" $D e3.log 'changed since the preflight' "$OUT/$V.s0i.snap" -v mode=kodhane_only -v uid=$U7 -v confirm_uid=$U7 -v approval_ref=TEST-1 -v expect=$T6
  else fail "C-E3 tokens of u6/u7 equal ($T6 / $T7)"; fi
  P -d $D -c "delete from auth.users where id in ('$U6', '$U7')" >/dev/null
  local m u t tag
  for m in full kodhane_only; do
    if [[ $m == full ]]; then u=$U1; t=$T1; tag=F; else u=$U3; t=$T3; tag=K; fi
    echo "== [$V] $m: refusals"
    refused "$tag-G1 no approval_ref" $D ${m}_g1.log 'approval_ref missing' "$OUT/$V.s0.snap" -v mode=$m -v uid=$u -v confirm_uid=$u -v expect=$t
    refused "$tag-G2 empty approval_ref" $D ${m}_g2.log 'approval_ref .*is required' "$OUT/$V.s0.snap" -v mode=$m -v uid=$u -v confirm_uid=$u -v approval_ref=' ' -v expect=$t
    refused "$tag-G3 confirm_uid differs" $D ${m}_g3.log 'confirm_uid does not match uid' "$OUT/$V.s0.snap" -v mode=$m -v uid=$u -v confirm_uid=$U2 -v approval_ref=TEST-1 -v expect=$t
    refused "$tag-G4 expect token wrong" $D ${m}_g4.log 'changed since the preflight' "$OUT/$V.s0.snap" -v mode=$m -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=000000000000
    refused "$tag-G5 unknown auth user" $D ${m}_g5.log 'not found; nothing deleted' "$OUT/$V.s0.snap" -v mode=$m -v uid=$NOBODY -v confirm_uid=$NOBODY -v approval_ref=TEST-1 -v expect=$(token $D $NOBODY)
    P -d $D -c "insert into public.acik_ofis_save_backups (user_id, revision, payload, reason) values ('$u', 9, '{}', 'manual')" >/dev/null; snap $D > "$OUT/$V.s0d.snap"
    refused "$tag-G6 Açık Ofis rows changed since the preflight -> refused" $D ${m}_g6.log 'changed since the preflight' "$OUT/$V.s0d.snap" -v mode=$m -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=$t
    P -d $D -c "delete from public.acik_ofis_save_backups where user_id = '$u' and revision = 9" >/dev/null
    P -d $D -c "update auth.users set email = 'changed-' || email where id = '$u'" >/dev/null; snap $D > "$OUT/$V.s0e.snap"
    refused "$tag-E1 auth e-mail changed since the preflight -> refused" $D ${m}_e1.log 'account \(id / e-mail / created_at\) changed since the preflight' "$OUT/$V.s0e.snap" -v mode=$m -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=$t
    P -d $D -c "update auth.users set email = substr(email, 9) where id = '$u'" >/dev/null
    local CA; CA=$(PA -d $D -c "select coalesce(created_at::text, 'null') from auth.users where id = '$u'")
    P -d $D -c "update auth.users set created_at = coalesce(created_at, now()) - interval '1 second' where id = '$u'" >/dev/null; snap $D > "$OUT/$V.s0e.snap"
    refused "$tag-E2 auth created_at changed since the preflight -> refused" $D ${m}_e2.log 'changed since the preflight' "$OUT/$V.s0e.snap" -v mode=$m -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=$t
    if [[ $CA == null ]]; then P -d $D -c "update auth.users set created_at = null where id = '$u'" >/dev/null; else P -d $D -c "update auth.users set created_at = '$CA' where id = '$u'" >/dev/null; fi
    [[ $(token $D $u) == "$t" ]] && pass "$tag-E2b e-mail / created_at restored -> the same token again" || fail "$tag-E2b token not restored"
    echo "== [$V] $m: error in the middle of the transaction"
    if [[ $m == full ]]; then
      boom $D "create trigger kd_test_boom before delete on auth.users for each row when (old.id = '$U1') execute function t.boom()"
      refused "F-F1 failure at the last step (auth.users) after Kodhane + Açık Ofis + audit deletes" $D full_f1.log 'injected failure in users' "$OUT/$V.s0.snap" -v mode=full -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=$t
      unboom $D auth.users
      boom $D "create trigger kd_test_boom before delete on public.acik_ofis_profiles for each row execute function t.boom()"
      refused "F-F2 failure at acik_ofis_profiles (after the Kodhane steps)" $D full_f2.log 'injected failure in acik_ofis_profiles' "$OUT/$V.s0.snap" -v mode=full -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=$t
      unboom $D public.acik_ofis_profiles
      P -d $D -c "create table public.zz_other_game (user_id uuid references auth.users on delete cascade)" -c "insert into public.zz_other_game values ('$U1')" >/dev/null
      snap $D > "$OUT/$V.s0o.snap"
      refused "F-B0 full refuses when another (non-Kodhane, non-AO) table references the user" $D full_b0.log 'BLOCKED: rows outside Kodhane / Açık Ofis \(public.zz_other_game=1\)' "$OUT/$V.s0o.snap" -v mode=full -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=$(token $D $U1)
      P -d $D -c "drop table public.zz_other_game" >/dev/null
    else
      boom $D "create trigger kd_test_boom before delete on public.kodhane_save_backups for each row execute function t.boom()"
      refused "K-F1 failure at step 2 (kodhane_save_backups) after step 1 + trigger copy" $D ko_f1.log 'injected failure in kodhane_save_backups' "$OUT/$V.s0.snap" -v mode=$m -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=$t
      unboom $D public.kodhane_save_backups
      boom $D "create trigger kd_test_boom after delete on public.kodhane_saves for each row execute function t.boom()"
      refused "K-F2 failure right after step 1 (kodhane_saves row gone, copy written)" $D ko_f2.log 'injected failure in kodhane_saves' "$OUT/$V.s0.snap" -v mode=$m -v uid=$u -v confirm_uid=$u -v approval_ref=TEST-1 -v expect=$t
      unboom $D public.kodhane_saves
    fi
    r=$(PA -d $D -c "select (select count(*) from public.kodhane_save_backups where reason = 'delete') + (select count(*) from public.acik_ofis_save_backups where reason = 'delete')")
    [[ $r == 0 ]] && pass "$tag-F3 no 'delete' copy (either game) left behind by the failed runs" || fail "$tag-F3 $r copies left"
  done

  echo "== [$V] full: delete u1 (both games)"
  P -d $D -c "update auth.users set last_sign_in_at = now() where id = '$U1'" \
    -c "insert into auth.audit_log_entries (instance_id, id, payload, created_at) values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), json_build_object('action', 'login', 'actor_id', '$U1', 'log_type', 'account'), now())" >/dev/null
  [[ $(token $D $U1) == "$T1" ]] && pass "F-E4 last_sign_in_at + a new audit row since the preflight: the token stays the same" || fail "F-E4 token changed"
  local lb0 lbao0 lb70; lb $D > "$OUT/$V.lb0.txt"; lbao $D > "$OUT/$V.lbao0.txt"; lb7 $D > "$OUT/$V.lb70.txt"; snap $D $U1 > "$OUT/$V.s_oth_u1.0"
  if del $D full_d1.log -v mode=full -v uid=$U1 -v confirm_uid=$U1 -v approval_ref=TEST-ONAY-1 -v expect=$T1; then
    r=$(grep -oE 'kodhane account delete OK .*' "$OUT/$V.full_d1.log")
    [[ "$r" == *"kodhane_saves 1, kodhane delete copies 1, kodhane_save_backups 2 (incl. copies), kodhane_event_log_carry 0, kodhane_profiles 1, acik_ofis_saves 1, acik_ofis delete copies 1, acik_ofis_save_backups 2 (incl. copies), acik_ofis_profiles 1, other acik_ofis rows 0, audit_log_entries 4, auth.refresh_tokens 2, auth.flow_state 1, auth.users 1"* ]] \
      && pass "F-R1 full delete: every step with the expected count, in-transaction check 0 rows" || fail "F-R1 summary: $r"
  else fail "F-R1 full delete failed: $(err full_d1.log)"; fi
  if verify $D full_v1.log -v mode=full -v uid=$U1 && grep -q 'verify OK (full)' "$OUT/$V.full_v1.log"; then
    pass "F-V1 verify full: 0 rows in all $(grep -cE '\| +0 \|' "$OUT/$V.full_v1.log") counted tables, audit log included"; else fail "F-V1 verify: $(err full_v1.log)"; fi
  verify $D full_v2.log -v mode=full -v uid=$U2 && fail "F-V2 verify passed for u2" || { grep -q 'rows left for' "$OUT/$V.full_v2.log" && pass "F-V2 verify full fails when rows are left (u2)" || fail "F-V2 wrong error"; }
  snap $D $U1 > "$OUT/$V.s_oth_u1.1"; diff -q "$OUT/$V.s_oth_u1.0" "$OUT/$V.s_oth_u1.1" >/dev/null && pass "F-B1 other users unchanged ($(wc -l < "$OUT/$V.s_oth_u1.1") tables incl. audit log)" || fail "F-B1 other users changed"
  lb $D > "$OUT/$V.lb1.txt"; diff <(grep -v '^Silinecek Bir|' "$OUT/$V.lb0.txt") "$OUT/$V.lb1.txt" >/dev/null && grep -q '^Silinecek Bir|' "$OUT/$V.lb0.txt" \
    && pass "F-B2 Kodhane leaderboard: u1's row gone, the others identical" || fail "F-B2 Kodhane leaderboard"
  lbao $D > "$OUT/$V.lbao1.txt"; diff <(grep -vE '^kl\|Silinecek Bir\||^al\|\([0-9]+,"AO Silinecek Bir"' "$OUT/$V.lbao0.txt" | sed -E 's/^al\|\([0-9]+,/al|(/') <(sed -E 's/^al\|\([0-9]+,/al|(/' "$OUT/$V.lbao1.txt") >/dev/null \
    && [[ $(wc -l < "$OUT/$V.lbao0.txt") -eq $(( $(wc -l < "$OUT/$V.lbao1.txt") + 2 )) ]] && pass "F-B3 both Açık Ofis leaderboards: u1's rows gone, the others identical" || fail "F-B3 AO leaderboards: $(diff "$OUT/$V.lbao0.txt" "$OUT/$V.lbao1.txt" | tr '\n' ' ')"
  if [[ $V == ab ]]; then lb7 $D > "$OUT/$V.lb71.txt"; diff <(grep -v '^Silinecek Bir|' "$OUT/$V.lb70.txt") "$OUT/$V.lb71.txt" >/dev/null && pass "F-B4 kodhane_leaderboard_v7: u1's row gone, the others identical" || fail "F-B4 v7"; fi
  dump $D > "$OUT/$V.dump1.sql"; diff -q "$OUT/$V.dump0.sql" "$OUT/$V.dump1.sql" >/dev/null && pass "F-B5 public + auth schema diff empty" || fail "F-B5 schema changed"

  echo "== [$V] full: re-created with the SAME id and e-mail"
  P -d $D -c "insert into auth.users (id, email) values ('$U1', 'u1-v22-test@example.invalid')" >/dev/null
  got=$(preflight $D $U1 | awk -F'|' 'NF == 6 && $4 != 0 {printf "%s=%s ", $2, $4}')
  [[ "$got" == "auth.users=1 " ]] && pass "F-S1 re-created account: only the new auth.users row (0 game rows, 0 audit rows)" || fail "F-S1 got: $got"
  r=$(PA -d $D -c "select t.login('$U1')" -c "select (select count(*) from public.kodhane_list_save_backups()) || '/' || (select count(*) from public.acik_ofis_list_save_backups())" | tail -n 1)
  [[ $r == 0/0 ]] && pass "F-S2 backups visible to the re-created user: Kodhane 0, Açık Ofis 0" || fail "F-S2 $r"
  r=$(PA -d $D -c "select t.login('$U1')" -c "do \$\$ begin perform public.kodhane_restore_save('$OLDK1'); raise notice 'K RESTORED'; exception when others then raise notice 'K %', sqlstate; end \$\$" \
    -c "do \$\$ begin perform public.acik_ofis_restore_save('$OLDA1'); raise notice 'A RESTORED'; exception when others then raise notice 'A %', sqlstate; end \$\$" 2>&1 | grep -oE '(K|A) [A-Z0-9]+$' | tr '\n' ' ')
  [[ "$r" == "K PT404 A PT404 " ]] && pass "F-S3 old backup ids cannot be restored in either game (PT404)" || fail "F-S3 $r"
  r=$(PA -d $D -c "insert into public.kodhane_profiles (user_id, nickname) values ('$U1', 'Yeni Bir')" -c "select t.login('$U1')" -c "select t.kpush(t.ksave(450000000))" -c "select t.logout()" \
    -c "insert into public.acik_ofis_saves (user_id, data, save_version) values ('$U1', jsonb_build_object('v', 2, 'startedAt', t.ms('10 hours'), 'lastSaved', t.ms('2 minutes'), 'money', 1, 'totalEarned', 50000, 'stage', 1), 2)" \
    -c "select (select best_score from public.kodhane_saves where user_id = '$U1') || '/' || (select best_score from public.acik_ofis_saves where user_id = '$U1')" | tail -n 1)
  [[ "$r" == "450000000/50000" ]] && pass "F-S4 new saves start from the new scores only (Kodhane 4.5e8 not 5e8, Açık Ofis 5e4 not 7e4)" || fail "F-S4 $r"
  ! lb $D | grep -q '|500000000|' && lb $D | grep -q '^Yeni Bir|450000000|' && pass "F-S5 Kodhane leaderboard: only the new score" || fail "F-S5 leaderboard"

  echo "== [$V] full: u4 (Kodhane only), re-signup with a NEW id and the same e-mail"
  snap $D $U4 > "$OUT/$V.s_oth_u4.0"; ao $D > "$OUT/$V.ao_u4.0"
  del $D full_d4.log -v mode=full -v uid=$U4 -v confirm_uid=$U4 -v approval_ref=TEST-ONAY-2 -v expect=$(token $D $U4) && grep -q 'acik_ofis_saves 0, .*audit_log_entries 1, ' "$OUT/$V.full_d4.log" \
    && pass "F-R2 full delete of a Kodhane-only user (0 Açık Ofis rows, 1 audit row)" || fail "F-R2 $(err full_d4.log)"
  verify $D full_v4.log -v mode=full -v uid=$U4 && pass "F-V3 verify full u4: 0 rows" || fail "F-V3 verify u4"
  snap $D $U4 > "$OUT/$V.s_oth_u4.1"; ao $D > "$OUT/$V.ao_u4.1"
  diff -q "$OUT/$V.s_oth_u4.0" "$OUT/$V.s_oth_u4.1" >/dev/null && diff -q "$OUT/$V.ao_u4.0" "$OUT/$V.ao_u4.1" >/dev/null && pass "F-B6 u4 delete: other users and Açık Ofis unchanged" || fail "F-B6 changed"
  r=$(PA -d $D -c "insert into auth.users (id, email) values ('$U5', 'u4-v22-test@example.invalid')" -c "insert into public.kodhane_profiles (user_id, nickname) values ('$U5', 'Yeni Dort')" \
    -c "select t.login('$U5')" -c "select count(*) from public.kodhane_list_save_backups()" -c "select t.kpush(t.ksave(450000000))" -c "select t.logout()" \
    -c "select best_score from public.kodhane_saves where user_id = '$U5'" | sed '/^$/d' | tr '\n' ' ')
  [[ "$r" == "0 450000000 " ]] && pass "F-S6 same e-mail, new id: 0 backups, best_score = new save (old 8e8 not back)" || fail "F-S6 got: $r"

  echo "== [$V] kodhane_only: u3 (plays both games)"
  snap $D $U3 > "$OUT/$V.s_oth_u3.0"; snap_of $D $U3 > "$OUT/$V.kept_u3.0"; ao $D > "$OUT/$V.ao_u3.0"; lbao $D > "$OUT/$V.lbao_u3.0"
  lb $D > "$OUT/$V.lb_u3.0"; lb7 $D > "$OUT/$V.lb7_u3.0"; dump $D > "$OUT/$V.dump_u3.0"
  T3=$(token $D $U3)
  P -d $D -c "update auth.users set last_sign_in_at = now() where id = '$U3'" -c "insert into auth.sessions (id, user_id) values ('aaaaaaaa-0000-4000-8000-000000000005', '$U3')" \
    -c "insert into auth.audit_log_entries (instance_id, id, payload, created_at) values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), json_build_object('action', 'login', 'actor_id', '$U3', 'log_type', 'account'), now())" >/dev/null
  [[ $(token $D $U3) == "$T3" ]] && pass "K-E4 new login since the preflight (last_sign_in_at, a new session, an audit row): the token stays the same" || fail "K-E4 token changed"
  snap $D $U3 > "$OUT/$V.s_oth_u3.0"; snap_of $D $U3 > "$OUT/$V.kept_u3.0"
  local OTH_SESS; OTH_SESS=$(PA -d $D -c "select md5(string_agg(s::text, '|' order by s::text)) || '/' || count(*) from auth.sessions s where user_id <> '$U3'")$(PA -d $D -c "select '/' || md5(string_agg(r::text, '|' order by r::text)) || '/' || count(*) from auth.refresh_tokens r where user_id <> '$U3'")
  if del $D ko_d1.log -v mode=kodhane_only -v uid=$U3 -v confirm_uid=$U3 -v approval_ref=TEST-ONAY-3 -v expect=$T3; then
    r=$(grep -oE 'kodhane account delete OK .*' "$OUT/$V.ko_d1.log")
    [[ "$r" == *"kodhane_saves 1, kodhane delete copies 1, kodhane_save_backups 2 (incl. copies), kodhane_event_log_carry 0, auth.refresh_tokens 3, auth.sessions 3 (sessions closed); kept: kodhane_profiles, auth user, audit log, Açık Ofis"* ]] \
      && pass "K-R1 kodhane_only delete with the pre-login token: saves 1, delete copy 1, backups 2, carry 0, refresh tokens 3, sessions 3" || fail "K-R1 summary: $r"
  else fail "K-R1 kodhane_only delete failed: $(err ko_d1.log)"; fi
  verify $D ko_v1.log -v mode=kodhane_only -v uid=$U3
  if grep -q 'verify OK (kodhane_only)' "$OUT/$V.ko_v1.log"; then pass "K-V1 verify kodhane_only: Kodhane saves/backups 0  -- $(grep -oE 'kept: .*' "$OUT/$V.ko_v1.log")"; else fail "K-V1 $(err ko_v1.log)"; fi
  verify $D ko_v2.log -v mode=full -v uid=$U3 && fail "K-V2 verify full passed after kodhane_only" || pass "K-V2 verify full still fails after kodhane_only (kept rows are real)"
  snap_of $D $U3 > "$OUT/$V.kept_u3.1"; diff -q "$OUT/$V.kept_u3.0" "$OUT/$V.kept_u3.1" >/dev/null \
    && pass "K-K1 kept rows identical: kodhane_profiles, Açık Ofis save/profile/backups, auth rows, audit log" || fail "K-K1 kept rows changed: $(diff "$OUT/$V.kept_u3.0" "$OUT/$V.kept_u3.1" | tr '\n' ' ')"
  r=$(PA -d $D -c "select (select count(*) from public.kodhane_saves where user_id = '$U3') || '/' || (select count(*) from public.kodhane_save_backups where user_id = '$U3') || '/' || (select count(*) from public.kodhane_profiles where user_id = '$U3') || '/' || (select count(*) from auth.users where id = '$U3')")
  [[ $r == 0/0/1/1 ]] && pass "K-K2 only the kept rows remain: kodhane_saves 0, kodhane_save_backups 0, kodhane_profiles 1, auth.users 1" || fail "K-K2 $r"
  r=$(PA -d $D -c "select (select count(*) from auth.sessions where user_id = '$U3') || '/' || (select count(*) from auth.refresh_tokens where user_id = '$U3') || '/' || (select count(*) from auth.refresh_tokens where session_id in ('aaaaaaaa-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000004'))")
  [[ $r == 0/0/0 ]] && pass "K-O1 every session of u3 closed: auth.sessions 0, auth.refresh_tokens 0 (session-bound and unbound)" || fail "K-O1 $r"
  r=$(PA -d $D -c "select md5(string_agg(s::text, '|' order by s::text)) || '/' || count(*) from auth.sessions s where user_id <> '$U3'")$(PA -d $D -c "select '/' || md5(string_agg(r::text, '|' order by r::text)) || '/' || count(*) from auth.refresh_tokens r where user_id <> '$U3'")
  [[ "$r" == "$OTH_SESS" && "$r" == */1/*/1 ]] && pass "K-O2 sessions and refresh tokens of other users untouched (u2: 1 session, 1 refresh token, rows identical)" || fail "K-O2 $OTH_SESS -> $r"
  snap $D $U3 > "$OUT/$V.s_oth_u3.1"; diff -q "$OUT/$V.s_oth_u3.0" "$OUT/$V.s_oth_u3.1" >/dev/null && pass "K-B1 other users unchanged" || fail "K-B1 other users changed"
  ao $D > "$OUT/$V.ao_u3.1"; lbao $D > "$OUT/$V.lbao_u3.1"
  diff -q "$OUT/$V.ao_u3.0" "$OUT/$V.ao_u3.1" >/dev/null && cmp -s "$OUT/$V.lbao_u3.0" "$OUT/$V.lbao_u3.1" && grep -q '^kl|Iki Oyunlu Uc|80000|' "$OUT/$V.lbao_u3.1" \
    && pass "K-A1 Açık Ofis byte-identical: data, kodhane_leaderboard('acik_ofis') + acik_ofis_leaderboard (nickname 'Iki Oyunlu Uc' still there), functions, triggers" || fail "K-A1 Açık Ofis changed"
  lb $D > "$OUT/$V.lb_u3.1"; diff <(grep -v '^Iki Oyunlu Uc|' "$OUT/$V.lb_u3.0") "$OUT/$V.lb_u3.1" >/dev/null && grep -q '^Iki Oyunlu Uc|450000000|' "$OUT/$V.lb_u3.0" \
    && pass "K-L1 kodhane_leaderboard v6 (anon): u3's row gone although the profile stays, the others identical" || fail "K-L1 v6"
  r=$(lb_as $D $U3); [[ "$r" != *"Iki Oyunlu Uc"* && "$r" != *"|t|"* && "$r" != *",t,"* ]] && pass "K-L2 kodhane_leaderboard v6 as u3 herself: no row, no own pending row" || fail "K-L2 $r"
  if [[ $V == ab ]]; then
    lb7 $D > "$OUT/$V.lb7_u3.1"; diff <(grep -v '^Iki Oyunlu Uc|' "$OUT/$V.lb7_u3.0") "$OUT/$V.lb7_u3.1" >/dev/null && grep -q '^Iki Oyunlu Uc|' "$OUT/$V.lb7_u3.0" \
      && pass "K-L3 kodhane_leaderboard_v7 (anon): u3's row gone, the others identical" || fail "K-L3 v7"
    r=$(lb7_as $D $U3); [[ "$r" != *"Iki Oyunlu Uc"* && "$r" != *",t,"* ]] && pass "K-L4 kodhane_leaderboard_v7 as u3: no row" || fail "K-L4 $r"
  fi
  dump $D > "$OUT/$V.dump_u3.1"; diff -q "$OUT/$V.dump_u3.0" "$OUT/$V.dump_u3.1" >/dev/null && pass "K-B2 public + auth schema diff empty" || fail "K-B2 schema changed"
  echo "== [$V] kodhane_only: the same user writes a new Kodhane save"
  r=$(PA -d $D -c "select t.login('$U3')" -c "select t.kpush(t.ksave(400000000))" -c "select count(*) from public.kodhane_list_save_backups()" -c "select t.logout()" \
    -c "select best_score from public.kodhane_saves where user_id = '$U3'" | sed '/^$/d' | tr '\n' ' ')
  [[ "$r" == "0 400000000 " ]] && pass "K-S1 new Kodhane save: 0 old backups, best_score = new save 4e8 (old 4.5e8 not back)" || fail "K-S1 $r"
  r=$(PA -d $D -c "select t.login('$U3')" -c "do \$\$ begin perform public.kodhane_restore_save('$OLDK3'); raise notice 'K RESTORED'; exception when others then raise notice 'K %', sqlstate; end \$\$" 2>&1 | grep -oE 'K [A-Z0-9]+$')
  [[ "$r" == "K PT404" ]] && pass "K-S2 old Kodhane backup id cannot be restored (PT404)" || fail "K-S2 $r"
  lb $D | grep -q '^Iki Oyunlu Uc|400000000|' && ! lb $D | grep -q '^Iki Oyunlu Uc|450000000|' && pass "K-S3 Kodhane leaderboard shows the new score only, same nickname" || fail "K-S3"
  if [[ $V == ab ]]; then lb7 $D | grep -q '^Iki Oyunlu Uc|400000000|' && pass "K-S4 v7 shows the new score only" || fail "K-S4 v7"; fi
  ao $D > "$OUT/$V.ao_u3.2"; diff -q "$OUT/$V.ao_u3.0" "$OUT/$V.ao_u3.2" >/dev/null && pass "K-A2 Açık Ofis still byte-identical after the new Kodhane save" || fail "K-A2 Açık Ofis changed"
  P -d postgres -c "drop database if exists $D" >/dev/null 2>&1
}

logsuite() {   # L-*: progress log rows of the user (base + A + B + log)
  local D=kd_log r f T3 n3 n1 oth0 oth1; V=abl
  echo "== [$V] setup (A + B + progress log)"
  fresh $D
  P -d $D -1 -f - < "$MIGA" >/dev/null 2>&1 && P -d $D -1 -f - < "$MIGB" >/dev/null 2>&1 && P -d $D -f - < "$MIGL" >/dev/null 2>&1 || { fail "L-setup A+B+log"; return; }
  seed $D || { fail "L-setup seed"; return; }
  plog() { PA -d $D -c "select count(*) from public.kodhane_progress_log where user_id = '$1'"; }
  plog_oth() { PA -d $D -c "select md5(coalesce(string_agg(l::text, '|' order by l.id), '')) || '/' || count(*) from public.kodhane_progress_log l where user_id <> all (array['$U1', '$U3', '$U4']::uuid[])"; }
  plw() { PA -d $D -c "select t.login('$1')" -c "update public.kodhane_saves set data = data || '{\"shares\": $2}', revision = revision + 1 where user_id = auth.uid()" -c "select t.logout()" >/dev/null; }
  plw $U1 7; plw $U3 7; plw $U3 8; plw $U4 9; plw $U2 5
  r="$(plog $U1)/$(plog $U2)/$(plog $U3)/$(plog $U4)"
  [[ $r =~ ^[1-9][0-9]*/[1-9][0-9]*/[1-9][0-9]*/[1-9][0-9]*$ ]] && pass "L-0 every seeded user has progress log rows ($r)" || fail "L-0 log rows $r"
  preflight $D $U3 > "$OUT/$V.pre_u3.txt"; f="$OUT/$V.pre_u3.txt"; n3=$(plog $U3)
  grep -qx "kodhane|public.kodhane_progress_log|user_id|$n3|delete|delete" $f && pass "L-P1 preflight lists public.kodhane_progress_log ($n3 rows of u3), deleted in both modes" || fail "L-P1 $(grep progress_log $f)"
  grep -qE "\|OK: deletes $((2 + n3)) Kodhane rows \(saves, backups, progress log, carry\)" $f && pass "L-P2 kodhane_only verdict counts the log rows (saves 1 + backups 1 + log $n3)" || fail "L-P2 $(grep -oE 'OK: deletes [0-9]+ Kodhane rows[^+]*' $f)"
  T3=$(token $D $U3); plw $U3 11
  [[ $(token $D $U3) == "$T3" && $(plog $U3) -gt $n3 ]] && pass "L-E1 the player keeps playing after the preflight (new log rows): the expect token stays the same" || fail "L-E1 token / log $(plog $U3)"
  n3=$(plog $U3); oth0=$(plog_oth)
  if del $D l_ko.log -v mode=kodhane_only -v uid=$U3 -v confirm_uid=$U3 -v approval_ref=TEST-ONAY-L1 -v expect=$T3 && grep -qE "kept: kodhane_profiles, auth user, audit log, Açık Ofis; kodhane_progress_log $n3; deletion log not installed \(no row\)\$" "$OUT/$V.l_ko.log"; then
    pass "L-K1 kodhane_only delete: summary reports kodhane_progress_log $n3"
  else fail "L-K1 $(err l_ko.log) $(grep -oE 'kodhane_progress_log [0-9]+' "$OUT/$V.l_ko.log")"; fi
  [[ $(plog $U3) == 0 && $(plog_oth) == "$oth0" ]] && pass "L-K2 u3's log rows 0, other users' log rows identical" || fail "L-K2 u3 $(plog $U3), others $oth0 -> $(plog_oth)"
  verify $D l_kv.log -v mode=kodhane_only -v uid=$U3 && pass "L-K3 verify kodhane_only OK" || fail "L-K3 $(err l_kv.log)"
  P -d $D -c "insert into public.kodhane_progress_log (user_id, event, field, actor_role, approval_ref) values ('$U3', 'telafi', 'shares', 'test', 'KD-TLF-2026-10-03-01')" >/dev/null
  if ! verify $D l_kv2.log -v mode=kodhane_only -v uid=$U3 && grep -q 'public.kodhane_progress_log=1' "$OUT/$V.l_kv2.log"; then pass "L-K4 verify kodhane_only fails on a leftover log row  -- $(err l_kv2.log)"; else fail "L-K4 verify passed with a leftover row"; fi
  P -d $D -c "delete from public.kodhane_progress_log where user_id = '$U3'" >/dev/null
  PA -d $D -c "select t.login('$U3')" -c "select t.kpush(t.ksave(400000000))" -c "select t.logout()" >/dev/null
  r=$(PA -d $D -c "select count(*) || '/' || count(*) filter (where rev_before is null) from public.kodhane_progress_log where user_id = '$U3'")
  [[ $r =~ ^[1-9][0-9]*/[0-9]+$ && ${r%/*} == "${r#*/}" ]] && pass "L-K5 a new Kodhane save after kodhane_only starts a fresh log (first insert rows only: $r)" || fail "L-K5 $r"
  n1=$(plog $U1); oth0=$(plog_oth)
  if del $D l_full.log -v mode=full -v uid=$U1 -v confirm_uid=$U1 -v approval_ref=TEST-ONAY-L2 -v expect=$(token $D $U1) && grep -qE "rows left: 0; kodhane_progress_log $n1; deletion log not installed \(no row\)\$" "$OUT/$V.l_full.log"; then
    pass "L-F1 full delete: summary reports kodhane_progress_log $n1"
  else fail "L-F1 $(err l_full.log) $(grep -oE 'kodhane_progress_log [0-9]+' "$OUT/$V.l_full.log")"; fi
  [[ $(plog $U1) == 0 && $(plog_oth) == "$oth0" ]] && verify $D l_fv.log -v mode=full -v uid=$U1 && pass "L-F2 u1's log rows 0, verify full OK, other users' log rows identical" || fail "L-F2 u1 $(plog $U1) $(err l_fv.log)"
  P -d $D -c "delete from auth.users where id = '$U4'" >/dev/null 2>&1
  [[ $(plog $U4) == 0 ]] && pass "L-F3 auth user deleted directly (GoTrue admin delete): log rows cascade (FK on delete cascade)" || fail "L-F3 $(plog $U4) rows left"
  P -d postgres -c "drop database if exists $D" >/dev/null 2>&1
}

suite kd_test base
suite kd_ab ab
logsuite
V=all
echo "== done: $PASSN pass / $FAILS fail (common ${NT[C]}, full ${NT[F]}, kodhane_only ${NT[K]}, progress log ${NT[L]}); image $(docker inspect "$CT" --format '{{.Config.Image}}'); artefacts in $OUT"
[[ $FAILS == 0 ]]
