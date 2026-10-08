-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (build -> verify.sql). Step 5 of docs/kodhane-v44b-install-runbook.md.
-- Runs AFTER the install in ONE transaction that ends with ROLLBACK: a synthetic auth user (id b44b0000-...-c0de, no
-- profile, so never on a leaderboard) writes like the clients do (PostgREST upsert as role authenticated). Nothing of it
-- stays; the only lasting trace is that the identity sequence of kodhane_progress_log moves on by a few numbers.
-- Prints CHECK|name|t|f lines and VERIFY|PASS or VERIFY|FAIL (no exception: the transaction is rolled back either way).
-- Needs the setting kd.lb_install (LB|kodhane md5 of the install step), put in by the install script.
select set_config('kd.uid', 'b44b0000-0000-4000-8000-00000000c0de', true);
create temp table _kd_v44b_chk (n int, name text, ok boolean, info text) on commit drop;
grant insert on _kd_v44b_chk to authenticated, anon;
-- real data fingerprint (everything except the synthetic user), before
create temp table _kd_v44b_real on commit drop as
  select 'saves'::text as k, count(*) as n, md5(coalesce(string_agg(concat_ws(':', user_id, revision, md5(data::text), best_score, best_stage, best_stage_id, updated_at), E'\n' order by user_id), '')) as h
    from public.kodhane_saves where user_id <> current_setting('kd.uid')::uuid
  union all select 'backups', count(*), md5(coalesce(string_agg(md5(b::text), E'\n' order by md5(b::text)), ''))
    from public.kodhane_save_backups b where user_id <> current_setting('kd.uid')::uuid
  union all select 'progress_log', count(*), md5(coalesce(string_agg(md5(l::text), E'\n' order by l.id), ''))
    from public.kodhane_progress_log l where user_id <> current_setting('kd.uid')::uuid
  union all select 'profiles', count(*), md5(coalesce(string_agg(md5(p::text), E'\n' order by p.user_id), ''))
    from public.kodhane_profiles p;
create temp table _kd_v44b_lb0 on commit drop as select * from public.kodhane_leaderboard(100, 'kodhane');

-- 0. the synthetic user
insert into _kd_v44b_chk select 0, 'synthetic user id unused', not exists (select 1 from auth.users where id = current_setting('kd.uid')::uuid), null;
insert into auth.users (id, aud, role, created_at, updated_at)
  values (current_setting('kd.uid')::uuid, 'authenticated', 'authenticated', now(), now());

create function pg_temp.kd_save(p_extra jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('version', 4, 'startedAt', floor(extract(epoch from now() - interval '20 hours') * 1000),
    'lastSaved', floor(extract(epoch from clock_timestamp()) * 1000), 'totalEarned', 2e6, 'runEarned', 2e6, 'cycleEarned', 2e6,
    'shares', 0, 'prestigeCount', 0, 'cycleRounds', 0, 'ipoCount', 0, 'ipoSharesEarned', 0, 'stage', 3) || p_extra $$;
-- the statement PostgREST runs for supabase-js upsert(row, {onConflict: 'user_id'}) with the cloud.js row
create function pg_temp.kd_up(p_data jsonb, p_rev bigint) returns void language sql as $$
  insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision)
  values (auth.uid(), p_data, 2, clock_timestamp(), p_rev)
  on conflict (user_id) do update set data = excluded.data, save_version = excluded.save_version, updated_at = excluded.updated_at,
    revision = excluded.revision $$;
grant execute on function pg_temp.kd_save(jsonb), pg_temp.kd_up(jsonb, bigint) to authenticated;

-- as the synthetic player
select set_config('request.jwt.claim.sub', current_setting('kd.uid'), true),
       set_config('request.jwt.claims', json_build_object('sub', current_setting('kd.uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $w$
declare st text; msg text;
begin
  -- 1. v4.4 client, first save (clientVersion, saveVersion 5)
  begin
    perform pg_temp.kd_up(pg_temp.kd_save('{"version": 5, "saveVersion": 5, "clientVersion": "v44b-verify", "stageId": "ajans", "tree": ["verify_1"]}'), 1);
    insert into _kd_v44b_chk values (1, 'v4.4 client first write (clientVersion, saveVersion 5) accepted', true, null);
  exception when others then get stacked diagnostics st = returned_sqlstate, msg = message_text;
    insert into _kd_v44b_chk values (1, 'v4.4 client first write (clientVersion, saveVersion 5) accepted', false, st || ' ' || msg);
  end;
  -- 2. v4.3.1 client (saveVersion 4) over the v4.4 save -> PT426
  begin
    perform pg_temp.kd_up(pg_temp.kd_save('{"saveVersion": 4, "totalEarned": 2.5e6}'), 2);
    insert into _kd_v44b_chk values (2, 'old client write (v4.3.1, saveVersion 4) refused with PT426', false, 'accepted');
  exception when others then get stacked diagnostics st = returned_sqlstate, msg = message_text;
    insert into _kd_v44b_chk values (2, 'old client write (v4.3.1, saveVersion 4) refused with PT426', st = 'PT426' and msg = 'save_version_too_old', st || ' ' || msg);
  end;
  -- 3. v4.3.0 client (no saveVersion) -> PT426
  begin
    perform pg_temp.kd_up(pg_temp.kd_save('{"totalEarned": 2.5e6}'), 2);
    insert into _kd_v44b_chk values (3, 'old client write (v4.3.0, no saveVersion) refused with PT426', false, 'accepted');
  exception when others then get stacked diagnostics st = returned_sqlstate, msg = message_text;
    insert into _kd_v44b_chk values (3, 'old client write (v4.3.0, no saveVersion) refused with PT426', st = 'PT426' and msg = 'save_version_too_old', st || ' ' || msg);
  end;
  -- 4. v4.4 client, next revision -> accepted
  begin
    perform pg_temp.kd_up(pg_temp.kd_save('{"version": 5, "saveVersion": 5, "clientVersion": "v44b-verify", "stageId": "ajans", "totalEarned": 3e6, "shares": 1, "prestigeCount": 1, "tree": ["verify_1"]}'), 2);
    insert into _kd_v44b_chk values (4, 'v4.4 client next write (revision 2) accepted', true, null);
  exception when others then get stacked diagnostics st = returned_sqlstate, msg = message_text;
    insert into _kd_v44b_chk values (4, 'v4.4 client next write (revision 2) accepted', false, st || ' ' || msg);
  end;
  -- 5. leaderboards as this player
  begin
    perform count(*) from public.kodhane_leaderboard_v7(100);
    perform count(*) from public.kodhane_leaderboard(100, 'kodhane');
    perform count(*) from public.kodhane_leaderboard(100, 'acik_ofis');
    insert into _kd_v44b_chk values (5, 'leaderboards v7 / v6 kodhane / v6 acik_ofis as authenticated: no error', true, null);
  exception when others then get stacked diagnostics st = returned_sqlstate, msg = message_text;
    insert into _kd_v44b_chk values (5, 'leaderboards v7 / v6 kodhane / v6 acik_ofis as authenticated: no error', false, st || ' ' || msg);
  end;
end $w$;
set local role anon;
select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '', true);
do $a$
declare st text; msg text;
begin
  perform count(*) from public.kodhane_leaderboard_v7(100);
  perform count(*) from public.kodhane_leaderboard(100, 'kodhane');
  insert into _kd_v44b_chk values (6, 'leaderboards v7 / v6 as anon: no error', true, null);
exception when others then get stacked diagnostics st = returned_sqlstate, msg = message_text;
  insert into _kd_v44b_chk values (6, 'leaderboards v7 / v6 as anon: no error', false, st || ' ' || msg);
end $a$;
reset role;

-- 7. the progress log got the accepted writes, not the refused ones
insert into _kd_v44b_chk
  select 7, 'progress log: rows for both accepted writes (client_version v44b-verify), none for the refused ones',
         count(*) filter (where rev_after = 1) >= 1 and count(*) filter (where rev_after = 2) >= 1
         and count(*) filter (where client_version is distinct from 'v44b-verify') = 0 and count(*) filter (where event = 'agac') = 1,
         count(*) || ' rows; events ' || coalesce(string_agg(distinct event, ','), '-')
    from public.kodhane_progress_log where user_id = current_setting('kd.uid')::uuid;
insert into _kd_v44b_chk
  select 8, 'synthetic save: revision 2, saveVersion 5, best_stage_id set by B',
         revision = 2 and (data ->> 'saveVersion') = '5' and best_stage_id is not null, 'best_stage_id ' || coalesce(best_stage_id, 'NULL')
    from public.kodhane_saves where user_id = current_setting('kd.uid')::uuid;
-- 9. leaderboard: same as at the start of this transaction and as right after the install
insert into _kd_v44b_chk
  select 9, 'Kodhane leaderboard unchanged by the synthetic writes (no profile -> not listed)',
         not exists ((select * from public.kodhane_leaderboard(100, 'kodhane') except all select * from _kd_v44b_lb0)
                     union all (select * from _kd_v44b_lb0 except all select * from public.kodhane_leaderboard(100, 'kodhane'))), null;
insert into _kd_v44b_chk
  select 10, 'Kodhane leaderboard = the one before / after the install (md5 of the install step)',
         md5(coalesce(string_agg(concat_ws(':', rank, nickname, score, stage, status), E'\n' order by rank, nickname), '')) = current_setting('kd.lb_install', true),
         'rows ' || count(*) || '; if f only: players wrote or the time-based rule moved since the install, see runbook'
    from _kd_v44b_lb0;
-- 11. real data untouched
insert into _kd_v44b_chk
  select 11, 'real users'' saves / backups / progress log / profiles untouched',
         not exists (
           (select * from _kd_v44b_real)
           except all
           (select 'saves'::text, count(*), md5(coalesce(string_agg(concat_ws(':', user_id, revision, md5(data::text), best_score, best_stage, best_stage_id, updated_at), E'\n' order by user_id), ''))
              from public.kodhane_saves where user_id <> current_setting('kd.uid')::uuid
            union all select 'backups', count(*), md5(coalesce(string_agg(md5(b::text), E'\n' order by md5(b::text)), ''))
              from public.kodhane_save_backups b where user_id <> current_setting('kd.uid')::uuid
            union all select 'progress_log', count(*), md5(coalesce(string_agg(md5(l::text), E'\n' order by l.id), ''))
              from public.kodhane_progress_log l where user_id <> current_setting('kd.uid')::uuid
            union all select 'profiles', count(*), md5(coalesce(string_agg(md5(p::text), E'\n' order by p.user_id), ''))
              from public.kodhane_profiles p)), null;
-- 12 + 13. account deletion removes the synthetic player's progress-log rows on THIS database (behaviour, not only the
-- catalog of delete-path-check; open point "EKSİK 4" of commit 43b9670: delete in both modes, verified live). Each in its
-- own subtransaction that is always undone (the DO block ends with an exception), so check 11 above and the rest of
-- this transaction are unaffected; the outer transaction is rolled back anyway.
--   12: the statement of step K3b of ops/kodhane_account_delete.sql (runs in BOTH modes, before the mode branch);
--       delete-path-check compares that file's md5 + statement.
--   13: the auth user delete (mode=full last step / GoTrue admin delete): ON DELETE CASCADE takes the log rows along.
do $kd_del$
declare v_uid uuid := current_setting('kd.uid')::uuid; v_before bigint; v_after bigint; v_others0 text; v_others1 text;
        v_mode text; v_err text;
begin
  select count(*) into v_before from public.kodhane_progress_log where user_id = v_uid;
  select count(*) || ':' || md5(coalesce(string_agg(md5(l::text), E'\n' order by l.id), '')) into v_others0
    from public.kodhane_progress_log l where user_id <> v_uid;
  foreach v_mode in array array['k3b', 'auth_user'] loop
    v_err := null; v_after := null; v_others1 := null;
    begin
      if v_mode = 'k3b' then
        execute 'delete from public.kodhane_progress_log where user_id = $1' using v_uid;          -- = K3b
      else
        delete from auth.users u where u.id = v_uid;                                                -- = mode full, last step
      end if;
      select count(*) into v_after from public.kodhane_progress_log where user_id = v_uid;
      select count(*) || ':' || md5(coalesce(string_agg(md5(l::text), E'\n' order by l.id), '')) into v_others1
        from public.kodhane_progress_log l where user_id <> v_uid;
      raise exception using errcode = 'P0K44', message = 'undo';
    exception
      when sqlstate 'P0K44' then null;
      when others then v_err := sqlstate || ' ' || sqlerrm;
    end;
    insert into _kd_v44b_chk select
      case v_mode when 'k3b' then 12 else 13 end,
      case v_mode when 'k3b' then 'account delete step K3b (both modes): the player''s progress-log rows -> 0, other players'' rows untouched (undone)'
                  else 'auth user delete (mode full / GoTrue admin delete): ON DELETE CASCADE removes the progress-log rows, others untouched (undone)' end,
      v_err is null and v_before >= 2 and v_after = 0 and v_others1 = v_others0,
      'rows ' || v_before || ' -> ' || coalesce(v_after::text, '?') || coalesce('; ERROR ' || v_err, '');
  end loop;
end $kd_del$;
insert into _kd_v44b_chk
  select 14, 'after the two undone deletes: the synthetic player''s log rows are back (subtransactions really undone)',
         count(*) >= 2, count(*) || ' rows'
    from public.kodhane_progress_log where user_id = current_setting('kd.uid')::uuid;
select concat_ws('|', 'CHECK', 'verify_' || n, coalesce(ok, false), name, info) from _kd_v44b_chk order by n;
select concat_ws('|', 'VERIFY', case when bool_and(coalesce(ok, false)) and count(*) = 15 then 'PASS' else 'FAIL' end, count(*) || ' checks')
  from _kd_v44b_chk;
