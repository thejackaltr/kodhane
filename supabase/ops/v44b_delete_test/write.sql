-- PARTIAL of supabase/ops/kodhane_v44b_delete_test.sh (write): two save writes as the test player (role authenticated,
-- the PostgREST upsert of cloud.js), committed; then the progress log must have rows for the uid.
select set_config('request.jwt.claim.sub', current_setting('kd.t_uid'), true),
       set_config('request.jwt.claims', json_build_object('sub', current_setting('kd.t_uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision)
values (auth.uid(), jsonb_build_object('version', 5, 'saveVersion', 5, 'clientVersion', 'deltest', 'totalEarned', 1000, 'runEarned', 1000,
          'cycleEarned', 1000, 'startedAt', floor(extract(epoch from now() - interval '1 hour') * 1000), 'lastSaved', floor(extract(epoch from now()) * 1000),
          'shares', 0, 'prestigeCount', 0, 'cycleRounds', 0, 'ipoCount', 0, 'tree', '["deltest_1"]'::jsonb), 2, clock_timestamp(), 1)
on conflict (user_id) do update set data = excluded.data, save_version = excluded.save_version, updated_at = excluded.updated_at, revision = excluded.revision;
insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision)
values (auth.uid(), (select data from public.kodhane_saves where user_id = auth.uid()) || '{"tree": ["deltest_1", "deltest_2"], "totalEarned": 2000}', 2, clock_timestamp(), 2)
on conflict (user_id) do update set data = excluded.data, save_version = excluded.save_version, updated_at = excluded.updated_at, revision = excluded.revision;
reset role;
select concat_ws('|', 'LOGROWS', count(*), coalesce(string_agg(distinct event, ','), '-'), coalesce(string_agg(distinct client_version, ','), '-'))
  from public.kodhane_progress_log where user_id = current_setting('kd.t_uid')::uuid;
do $w$
begin
  if (select count(*) from public.kodhane_progress_log where user_id = current_setting('kd.t_uid')::uuid) < 2 then
    raise exception 'STOP: no progress-log rows for the test user after two writes';
  end if;
end $w$;
