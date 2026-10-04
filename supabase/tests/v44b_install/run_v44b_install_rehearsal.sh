#!/usr/bin/env bash
# Full rehearsal of supabase/ops/kodhane_v44b_install.sh (package B + progress log) on a LOCAL THROWAWAY container.
# Never point this at the live database. The container ($RH_CT, supabase/postgres image) must hold $RH_BASE: the live
# schema (pg_dump -s of the shared DB, no data) = Kodhane v2.2 + Açık Ofis, before package A.
#   RH_CT=<container> bash supabase/tests/v44b_install/run_v44b_install_rehearsal.sh 2>&1 | tee /tmp/v44b-rehearsal.log
# Optional RH_LIVE_COPY: pseudonymized live data (auth.users ids + saves + profiles, 'Oyuncu N' nicknames), loaded verbatim.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SB="$(cd "$HERE/../.." && pwd)"
INST="$SB/ops/kodhane_v44b_install.sh"
CT="${RH_CT:-v44x-136}"; BASE="${RH_BASE:-v44_base}"; LIVE="${RH_LIVE_COPY:-/workspace/tmp/v44/a/live_copy.sql}"
OUT="${RH_OUT:-/tmp/v44b-rehearsal}"; rm -rf "$OUT"; mkdir -p "$OUT"; chmod 700 "$OUT"
DB=v44b_reh; DBR=v44b_reh_restore; DBN=v44b_reh_noa
PASS=0; FAILS=0
pass() { PASS=$((PASS + 1)); echo "PASS $*"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL $*"; }
P() { docker exec -i "$CT" psql -X -q -U supabase_admin -v ON_ERROR_STOP=1 "$@"; }
PA() { P -At "$@"; }
fresh() { P -d postgres -c "drop database if exists $1 with (force)" && P -d postgres -c "create database $1 template $BASE"; }
inst() { local db=$1 out=$2; shift 2; KODHANE_TARGET=local KODHANE_CT="$CT" KODHANE_DB=$db KODHANE_OUT="$out" KODHANE_BACKUP_DIR="${out}_backups" bash "$INST" "$@"; }
schema() { docker exec "$CT" pg_dump -U supabase_admin -d "$1" -s | grep -vE '^\\(un)?restrict |^-- Dumped (from|by)'; }
# data fingerprint: every row of the game tables (B's best_stage_id excluded: the column exists only while B is installed)
fp() { PA -d "$1" -c "select 'saves ' || count(*) || ' ' || md5(coalesce(string_agg(concat_ws(':', user_id, revision, md5(data::text), best_score, best_stage, updated_at), E'\n' order by user_id), '')) from public.kodhane_saves
  union all select 'ao_saves ' || count(*) || ' ' || md5(coalesce(string_agg(md5(s::text), E'\n' order by s.user_id), '')) from public.acik_ofis_saves s
  union all select 'profiles ' || count(*) || ' ' || md5(coalesce(string_agg(md5(p::text), E'\n' order by p.user_id), '')) from public.kodhane_profiles p
  union all select 'backups ' || count(*) || ' ' || md5(coalesce(string_agg(md5(b::text), E'\n' order by md5(b::text)), '')) from public.kodhane_save_backups b
  union all select 'users ' || count(*) || ' ' || md5(coalesce(string_agg(id::text, ',' order by id), '')) from auth.users"; }
same() { if diff "$2" "$3" > "$OUT/$1.diff"; then pass "$1 (diff empty)"; else fail "$1 (see $OUT/$1.diff)"; fi; }
step_ok() { local name=$1 db=$2 out=$3 st=$4 re=$5; inst "$db" "$out" $st > "$out.${st%% *}.log" 2>&1; local rc=$?
  local l="$out.${st%% *}.log"; if [[ $rc == 0 ]] && grep -qE "$re" "$l"; then pass "$name"; else fail "$name (rc $rc, $l)"; sed 's/^/     /' "$l" | tail -n 15; fi; }
step_stop() { local name=$1 db=$2 out=$3 st=$4 re=$5 l="$3.${4%% *}.stop.log"; inst "$db" "$out" $st > "$l" 2>&1; local rc=$?
  if [[ $rc != 0 ]] && grep -qE "$re" "$l"; then pass "$name"; else fail "$name (rc $rc, $l)"; sed 's/^/     /' "$l" | tail -n 15; fi; }
# as a player (PostgREST: role authenticated, jwt sub), one upsert like cloud.js; prints the error text, if any
play() { P -d $DB -c "select set_config('request.jwt.claim.sub', '$1', false); set role authenticated;
  insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision)
  values (auth.uid(), (select data from public.kodhane_saves where user_id = auth.uid()) || '$2'::jsonb, 2, clock_timestamp(),
          (select revision + 1 from public.kodhane_saves where user_id = auth.uid()))
  on conflict (user_id) do update set data = excluded.data, save_version = excluded.save_version, updated_at = excluded.updated_at, revision = excluded.revision" 2>&1 >/dev/null | grep -oE 'save_version_too_old|ERROR.*' | head -n1; }
U1=7e570000-0000-4000-8000-000000000001; U3=7e570000-0000-4000-8000-000000000003

echo "== 0. rehearsal DB = live schema + package A (as live since 2026-10-01) + live-like data"
fresh $DB >/dev/null || { echo "cannot create $DB from $BASE"; exit 1; }
P -d $DB -1 -f - < "$SB/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql" > "$OUT/a_apply.log" 2>&1
a=$(PA -d $DB -c "select md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure))")
[[ $a == 969e1dc203fa1877a57e2cf3fcc2727c ]] && pass "R0 package A on the rehearsal DB: md5 $a (= live)" || fail "R0 A md5 $a"
if [[ -r "$LIVE" ]]; then P -d $DB -f - < "$LIVE" > /dev/null && echo "   live copy loaded"; else echo "   (no live copy)"; fi
P -d $DB -f - < "$HERE/seed_extra.sql" > /dev/null || fail "seed"
r=$(PA -d $DB -c "select count(*) filter (where public.kodhane_score_plausible(data) is distinct from public.kodhane_score_plausible(data - 'clientVersion')) from public.kodhane_saves")
[[ $r == 0 ]] && pass "R0b A ignores data.clientVersion (client push before B is harmless for the leaderboard)" || fail "R0b $r saves differ"
PA -d $DB -c "select 'saves ' || count(*) || ', on leaderboard ' || (select count(*) from public.kodhane_leaderboard(100, 'kodhane')) from public.kodhane_saves"

R1="$OUT/run1"
echo "== 1. package steps on the rehearsal DB (backup -> preflight -> dryrun -> install -> verify)"
step_ok "S1 build (inputs = inputs.md5)" $DB $R1 build '^BUILD\|PASS'
step_ok "S2 backup" $DB $R1 backup '^BACKUP\|PASS'
bf=$(sed -n 's/^file //p' "$R1/backup.out")
[[ $(stat -c %a "$bf") == 600 && $(stat -c %a "$bf.md5") == 600 ]] && (cd "$(dirname "$bf")" && md5sum --quiet -c "$(basename "$bf").md5") \
  && [[ "$(basename "$bf")" =~ ^kodhane-shared-[0-9]{8}-[0-9]{4}\.dump$ ]] && pass "S2b backup name kodhane-shared-YYYYMMDD-HHMM.dump, mode 600, .md5 ok ($(grep '^toc' "$R1/backup.out"))" || fail "S2b backup file"
schema $DB > "$OUT/schema_pre.sql"; fp $DB > "$OUT/fp_pre.txt"
step_ok "S3 preflight" $DB $R1 preflight '^PREFLIGHT\|PASS'
grep -E '^INFO\|saves_by|^INFO\|saves_columns' "$R1/preflight.out" | sed 's/^/     /'
step_ok "S4 dryrun" $DB $R1 dryrun '^DRYRUN\|PASS'
grep -E '^objects new' "$R1.dryrun.log" | sed 's/^/     /'
schema $DB > "$OUT/schema_after_dryrun.sql"; fp $DB > "$OUT/fp_after_dryrun.txt"
same S4b_dryrun_left_schema_unchanged "$OUT/schema_pre.sql" "$OUT/schema_after_dryrun.sql"
same S4c_dryrun_left_data_unchanged "$OUT/fp_pre.txt" "$OUT/fp_after_dryrun.txt"
step_ok "S5 install (B, then progress log, one transaction)" $DB $R1 install 'objects install = dry-run: MATCH'
fp $DB > "$OUT/fp_after_install.txt"; same S5b_install_wrote_no_data "$OUT/fp_pre.txt" "$OUT/fp_after_install.txt"
step_ok "S6 verify (synthetic player, rolled back)" $DB $R1 verify 'objects verify = dry-run: MATCH'
grep -E '^CHECK\|verify_' "$R1/verify.out" | cut -d'|' -f2-4 | sed 's/^/     /'
r=$(grep -cE '^CHECK\|verify_1[234]\|t\|' "$R1/verify.out")$(grep -c '^VERIFY|PASS|15 checks' "$R1/verify.out")
[[ $r == 31 ]] && pass "S6d verify_12-14 (EKSİK 4 of 43b9670): account delete K3b + auth user cascade remove the synthetic log rows, both undone; VERIFY|PASS|15 checks" || fail "S6d $r"
fp $DB > "$OUT/fp_after_verify.txt"; same S6b_verify_left_no_data "$OUT/fp_pre.txt" "$OUT/fp_after_verify.txt"
r=$(PA -d $DB -c "select count(*) from public.kodhane_progress_log")$(PA -d $DB -c "select count(*) from auth.users where id = 'b44b0000-0000-4000-8000-00000000c0de'")
[[ $r == 00 ]] && pass "S6c after verify: progress log empty, no synthetic user" || fail "S6c $r"
grep -E '^OBJ\|FN\|' "$R1/objects_dryrun.txt" | cut -d'|' -f3,4 > "$OUT/fn_md5_dryrun.txt"

echo "== 2. players after the install (autocommit, as role authenticated)"
e=$(play $U1 '{"saveVersion": 4, "totalEarned": 5.1e6}'); [[ $e == *save_version_too_old* ]] && pass "P1 v4.4 save (sv 5) + v4.3.1 write -> PT426 save_version_too_old" || fail "P1 got '$e'"
e=$(play $U3 '{"saveVersion": 4, "totalEarned": 3.1e6, "cycleRounds": 1}'); [[ -z $e ]] && pass "P2 format 4 save (sv 4) + v4.3.1 write -> accepted (not guarded)" || fail "P2 got '$e'"
e=$(play $U1 '{"saveVersion": 5, "clientVersion": "4.4.2", "totalEarned": 5.2e6, "cycleRounds": 1}'); [[ -z $e ]] && pass "P3 v4.4.2 write -> accepted" || fail "P3 got '$e'"
r=$(PA -d $DB -c "select string_agg(distinct client_version, ',' order by client_version) || ' / ' || count(*) from public.kodhane_progress_log")
[[ $r == "4.4.2,saveVersion 4 / "* ]] && pass "P4 progress log: rows of the two accepted writes only ($r)" || fail "P4 $r"

echo "== 3. guards on an installed DB"
step_stop "G1 preflight on the installed DB -> STOP (B / progress log present)" $DB $R1 preflight 'already present'
schema $DB > "$OUT/schema_installed.sql"
P -d $DB -f - < "$R1/sql/install.sql" > "$OUT/g2.log" 2>&1
[[ $? != 0 ]] && grep -q 'STOP: kodhane_score_plausible is not package A' "$OUT/g2.log" && pass "G2 install.sql run again by hand (script gate bypassed) -> STOP inside the transaction (A md5)" || fail "G2 $(grep -m1 ERROR "$OUT/g2.log")"
schema $DB > "$OUT/schema_installed2.sql"; same G2b_schema_unchanged "$OUT/schema_installed.sql" "$OUT/schema_installed2.sql"

echo "== 4. rollback: progress log, then B (back to A)"
step_stop "B1 rollback without loss confirmation -> refused (log has rows), nothing changed" $DB $R1 rollback 'row\(s\) that would be lost'
schema $DB > "$OUT/schema_after_rb_refused.sql"; same B1b_schema_unchanged "$OUT/schema_installed.sql" "$OUT/schema_after_rb_refused.sql"
KODHANE_ALLOW_PROGRESS_LOG_LOSS=on step_ok "B2 rollback with KODHANE_ALLOW_PROGRESS_LOG_LOSS=on" $DB $R1 rollback '^ROLLBACK\|PASS'
grep -E '^CHECK\|rollback' "$R1/rollback_allow_loss.out" | sed 's/^/     /'
schema $DB > "$OUT/schema_after_rb.sql"; same B3_schema_after_rollback_equals_pre_install "$OUT/schema_pre.sql" "$OUT/schema_after_rb.sql"
grep -E '^OBJ\|' "$R1/rollback_allow_loss.out" > "$OUT/objects_after_rb.txt"; same B4_objects_after_rollback_equal_preflight "$R1/objects_preflight.txt" "$OUT/objects_after_rb.txt"
fp $DB | grep -v '^saves ' > "$OUT/fp_after_rb.txt"; grep -v '^saves ' "$OUT/fp_pre.txt" > "$OUT/fp_pre_nosaves.txt"
same B5_other_data_unchanged_by_rollback "$OUT/fp_pre_nosaves.txt" "$OUT/fp_after_rb.txt"
r=$(PA -d $DB -c "select count(*) from public.kodhane_saves where user_id in ('$U1', '$U3') and (data->>'totalEarned')::numeric in (5.2e6, 3.1e6)")
[[ $r == 2 ]] && pass "B6 saves written while B was installed survive the rollback" || fail "B6 $r"

echo "== 5. second full run after the rollback (repeatable)"
R2="$OUT/run2"
for s in build backup; do step_ok "S2-$s" $DB $R2 $s "^$(echo $s | tr a-z A-Z)\\|PASS"; done
schema $DB > "$OUT/schema_pre2.sql"; fp $DB > "$OUT/fp_pre2.txt"
for s in preflight dryrun install verify; do step_ok "S2-$s" $DB $R2 $s "^$(echo $s | tr a-z A-Z)\\|PASS"; done
bf2=$(sed -n 's/^file //p' "$R2/backup.out")
grep -E '^OBJ\|FN\|' "$R2/objects_dryrun.txt" | cut -d'|' -f3,4 > "$OUT/fn_md5_dryrun2.txt"
same S2-fn_md5_equal_to_run1 "$OUT/fn_md5_dryrun.txt" "$OUT/fn_md5_dryrun2.txt"

echo "== 5b. account deletion and the progress log (installed, live-like DB)"
step_ok "D1 delete-path-check (READ ONLY catalog proof + ops file md5)" $DB $R2 delete-path-check '^DELPATH\|PASS'
grep -E '^CHECK\|delpath' "$R2.delete-path-check.log" | cut -d'|' -f2,3 | tr '\n' ' ' | sed 's/^/     /'; echo
U2=7e570000-0000-4000-8000-000000000002
logn() { PA -d $DB -c "select count(*) from public.kodhane_progress_log where user_id = '$1'"; }
logoth() { PA -d $DB -c "select md5(coalesce(string_agg(l::text, '|' order by l.id), '')) || '/' || count(*) from public.kodhane_progress_log l where user_id <> all (string_to_array('$1', ',')::uuid[])"; }
e=$(play $U2 '{"saveVersion": 5, "tree": ["reh_1"], "totalEarned": 4.1e6}'); n0=$(logn $U2)
P -d $DB -c "select set_config('request.jwt.claim.sub', '$U2', false); set role authenticated; select public.kodhane_reset_save();" > /dev/null 2>&1
r=$(PA -d $DB -c "select count(*) || '/' || count(*) filter (where event = 'sifirlama') from public.kodhane_progress_log where user_id = '$U2'")
[[ -z $e && ${r%/*} -gt $n0 && ${r#*/} -ge 1 ]] && pass "D2 kodhane_reset_save keeps the log rows ($n0 before) and adds 'sifirlama' rows ($r)" || fail "D2 e='$e' before $n0 after $r"
n0=$(logn $U2); P -d $DB -c "delete from public.kodhane_saves where user_id = '$U2'" > /dev/null
[[ $(logn $U2) == "$n0" && $n0 -gt 0 ]] && pass "D3 a save-row DELETE (admin; players have no DELETE) leaves the log rows ($n0): only account deletion removes them" || fail "D3 $(logn $U2) vs $n0"
pre() { PA -F '|' -d $DB -v uid="$1" -f - < "$SB/ops/kodhane_account_delete_preflight.sql" 2>&1 | grep -E '^(OK|BLOCKED|STOP):' | awk -F'|' '{print $NF}'; }
play $U3 '{"saveVersion": 4, "tree": ["reh_1", "reh_2"]}' > /dev/null; play $U1 '{"saveVersion": 5, "clientVersion": "4.4.2", "tree": ["reh_1"]}' > /dev/null
for m in kodhane_only:$U3 full:$U1; do mode=${m%%:*}; u=${m#*:}; n=$(logn $u); o0=$(logoth $u); tok=$(pre $u)
  P -d $DB -v mode=$mode -v uid=$u -v confirm_uid=$u -v approval_ref=REH-$mode -v expect=$tok -f - < "$SB/ops/kodhane_account_delete.sql" > "$OUT/del_$mode.log" 2>&1; rc=$?
  P -d $DB -v mode=$mode -v uid=$u -f - < "$SB/ops/kodhane_account_delete_verify.sql" > "$OUT/delv_$mode.log" 2>&1; rv=$?
  [[ $rc == 0 && $rv == 0 && $n -gt 0 && $(logn $u) == 0 && $(logoth $u) == "$o0" ]] && pass "D4-$mode account delete: the uid's $n log rows -> 0, other users' rows identical, verify OK" || fail "D4-$mode rc $rc/$rv rows $n -> $(logn $u)"
done
DT="$OUT/deltest"; dt() { KODHANE_TARGET=local KODHANE_CT="$CT" KODHANE_DB=$DB KODHANE_OUT="$1" bash "$SB/ops/kodhane_v44b_delete_test.sh" $2; }
o0=$(logoth 00000000-0000-0000-0000-000000000000)
dt $DT create > "$OUT/dt_create.log" 2>&1 && pass "T1 deltest create ($(cut -d'|' -f2 "$DT/testuser.txt" | sed 's/@.*/@example.invalid/'))" || { fail "T1"; tail -5 "$OUT/dt_create.log"; }
dt $DT write > "$OUT/dt_write.log" 2>&1 && pass "T2 deltest write: $(grep -m1 '^LOGROWS' "$OUT/dt_write.log")" || { fail "T2"; tail -5 "$OUT/dt_write.log"; }
mkdir -p "$OUT/dt_fake1" "$OUT/dt_fake2"; tu=$(cut -d'|' -f1 "$DT/testuser.txt"); te=$(cut -d'|' -f2 "$DT/testuser.txt"); tc=$(cut -d'|' -f3 "$DT/testuser.txt")
echo "$U2|$te|$tc" > "$OUT/dt_fake1/testuser.txt"; echo "$tu|$te|2026-01-01T00:00:00.000000" > "$OUT/dt_fake2/testuser.txt"
dt "$OUT/dt_fake1" delete > "$OUT/dt_fake1.log" 2>&1; [[ $? != 0 ]] && grep -q 'not the recorded test account' "$OUT/dt_fake1.log" && pass "T3 guard: a real player's uid in testuser.txt -> STOP (e-mail), nothing deleted" || fail "T3 $(tail -2 "$OUT/dt_fake1.log")"
dt "$OUT/dt_fake2" delete > "$OUT/dt_fake2.log" 2>&1; [[ $? != 0 ]] && grep -q 'created_at differs' "$OUT/dt_fake2.log" && pass "T4 guard: right uid + e-mail, other created_at -> STOP" || fail "T4 $(tail -2 "$OUT/dt_fake2.log")"
[[ $(PA -d $DB -c "select count(*) from public.kodhane_saves where user_id = '$U2'") == 0 && $(logn $tu) -gt 0 ]] && pass "T5 after T3/T4 the test user's rows are still there (guards deleted nothing)" || fail "T5"
dt $DT delete > "$OUT/dt_delete.log" 2>&1 && pass "T6 deltest delete (preflight -> delete full -> verify -> 0 rows): $(grep -m1 '^DELETE|PASS' "$OUT/dt_delete.log" | cut -d'|' -f3)" || { fail "T6"; tail -8 "$OUT/dt_delete.log"; }
grep -E '^(LEFT|OTHERS)\|' "$OUT/dt_delete.log" | tr '\n' ' ' | sed 's/^/     /'; echo
[[ $(logoth 00000000-0000-0000-0000-000000000000) == "$o0" ]] && pass "T7 all other log rows identical after the delete test" || fail "T7"

echo "== 6. last resort: full restore of the run-1 backup"
# (a) into a new database: schema + data = the state at backup time
P -d postgres -c "drop database if exists $DBR with (force)" >/dev/null; P -d postgres -c "create database $DBR" >/dev/null
docker exec -i "$CT" pg_restore -U supabase_admin -d $DBR < "$bf" > "$OUT/restore_new.log" 2>&1; echo "   pg_restore into a new DB: exit $? ($(grep -c 'error' "$OUT/restore_new.log") error lines)"
schema $DBR > "$OUT/schema_restored.sql"; fp $DBR > "$OUT/fp_restored.txt"
same F1_restored_schema_equals_backup_time "$OUT/schema_pre.sql" "$OUT/schema_restored.sql"
same F2_restored_data_equals_backup_time "$OUT/fp_pre.txt" "$OUT/fp_restored.txt"
# (b) naive in-place pg_restore --clean over the installed DB: re-created objects pick up Supabase's default privileges
P -d postgres -c "drop database if exists ${DB}_naive with (force)" >/dev/null; P -d postgres -c "create database ${DB}_naive template $DB" >/dev/null
docker exec -i "$CT" pg_restore -U supabase_admin -d ${DB}_naive --clean --if-exists --single-transaction --exit-on-error < "$bf" > "$OUT/restore_naive.log" 2>&1
schema ${DB}_naive > "$OUT/schema_naive.sql"; P -d postgres -c "drop database ${DB}_naive with (force)" >/dev/null
n=$(diff "$OUT/schema_pre.sql" "$OUT/schema_naive.sql" | grep -c '^> GRANT')
[[ $n -gt 0 ]] && pass "F3 (why the prelude) naive pg_restore --clean in place adds $n GRANT lines (default privileges), so the package does not use it" || fail "F3 naive restore: $n extra grants"
# (c) the package's restore step in place, over the installed DB of run 2 (B + progress log present, a player write after it)
e=$(play 7e570000-0000-4000-8000-000000000005 '{"saveVersion": 5, "clientVersion": "4.4.2", "shares": 2}'); [[ -z $e ]] || fail "F4 pre-write: $e"
step_stop "F4 restore without KODHANE_RESTORE_CONFIRM -> refused" $DB $R2 "restore $bf2" 'KODHANE_RESTORE_CONFIRM'
KODHANE_RESTORE_CONFIRM=$(basename "$bf2") step_ok "F5 restore step (prelude + pg_restore --clean --if-exists, one transaction)" $DB $R2 "restore $bf2" '^RESTORE\|PASS'
schema $DB > "$OUT/schema_restored_inplace.sql"; fp $DB > "$OUT/fp_restored_inplace.txt"
same F6_in_place_schema_equals_backup_time "$OUT/schema_pre2.sql" "$OUT/schema_restored_inplace.sql"
same F7_in_place_data_equals_backup_time "$OUT/fp_pre2.txt" "$OUT/fp_restored_inplace.txt"
step_ok "F8 after the full restore: preflight PASS (back at A, B / progress log absent)" $DB $R2 preflight '^PREFLIGHT\|PASS'

echo "== 7. preflight / install guards on other states"
fresh $DBN >/dev/null
NO="$OUT/noa"; inst $DBN $NO build > /dev/null 2>&1
step_stop "N1 preflight without package A -> STOP (md5)" $DBN $NO preflight 'expected A 969e1dc2'
step_stop "N1b dryrun without a passed preflight -> refused" $DBN $NO dryrun 'preflight.out has no'
NR="$OUT/restored"; inst $DBR $NR build > /dev/null 2>&1
P -d $DBR -c "insert into auth.users (id, aud, role, created_at, updated_at) values ('7e570000-0000-4000-8000-000000000009', 'authenticated', 'authenticated', now(), now());
  insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision) values ('7e570000-0000-4000-8000-000000000009', '{\"saveVersion\": 6, \"totalEarned\": 1}', 2, now(), 1)" > /dev/null
step_stop "N2 a stored saveVersion 6 -> preflight STOP" $DBR $NR preflight 'saveVersion > 5'
P -d $DBR -c "delete from auth.users where id = '7e570000-0000-4000-8000-000000000009'" > /dev/null
step_ok "N3 restored DB: preflight PASS again" $DBR $NR preflight '^PREFLIGHT\|PASS'
schema $DBR > "$OUT/schema_r0.sql"
( P -d $DBR -c "begin; lock table public.kodhane_saves in row exclusive mode; select pg_sleep(12); commit;" > /dev/null 2>&1 ) & LPID=$!
sleep 2
step_stop "N4 a session holding a lock on kodhane_saves: dryrun gives up after lock_timeout 5 s" $DBR $NR dryrun 'lock timeout'
wait $LPID; schema $DBR > "$OUT/schema_r1.sql"; same N4b_nothing_changed "$OUT/schema_r0.sql" "$OUT/schema_r1.sql"
step_ok "N5 after the lock is gone: dryrun PASS" $DBR $NR dryrun '^DRYRUN\|PASS'

echo "== done: $PASS pass, $FAILS fail; artefacts in $OUT"
for d in $DB $DBR $DBN; do P -d postgres -c "drop database if exists $d with (force)" > /dev/null; done
[[ $FAILS == 0 ]]
