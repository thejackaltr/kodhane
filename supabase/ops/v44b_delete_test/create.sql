-- PARTIAL of supabase/ops/kodhane_v44b_delete_test.sh (create): one auth user, no password, no identity, no profile
-- (never on a leaderboard, cannot sign in). Needs kd.t_uid / kd.t_email (set by the script).
do $c$
begin
  if current_setting('kd.t_email') !~ '^kodhane-deltest-[0-9]{8}-[0-9]{6}@example\.invalid$' then
    raise exception 'STOP: not a test address';
  end if;
  if exists (select 1 from auth.users where id = current_setting('kd.t_uid')::uuid or email = current_setting('kd.t_email')) then
    raise exception 'STOP: id or e-mail already exists';
  end if;
end $c$;
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values ('00000000-0000-0000-0000-000000000000', current_setting('kd.t_uid')::uuid, 'authenticated', 'authenticated',
          current_setting('kd.t_email'), now(), now(), '{"provider": "deltest"}', '{"kodhane_deltest": true}');
select concat_ws('|', 'TESTUSER', id, email, to_char(created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'))
  from auth.users where id = current_setting('kd.t_uid')::uuid;
