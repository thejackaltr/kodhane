-- PARTIAL of supabase/ops/kodhane_v44b_delete_test.sh (after the full account delete, READ ONLY): 0 rows of the uid
-- everywhere (progress log, saves, backups, auth user, audit log), other users' log rows that existed before are still there.
-- Needs kd.t_uid and kd.t_others (count|max id of other users' log rows, recorded just before the delete).
select l from (
  select 1 as o, concat_ws('|', 'LEFT', 'kodhane_progress_log', count(*)) as l from public.kodhane_progress_log where user_id = current_setting('kd.t_uid')::uuid
  union all select 2, concat_ws('|', 'LEFT', 'kodhane_saves', count(*)) from public.kodhane_saves where user_id = current_setting('kd.t_uid')::uuid
  union all select 3, concat_ws('|', 'LEFT', 'kodhane_save_backups', count(*)) from public.kodhane_save_backups where user_id = current_setting('kd.t_uid')::uuid
  union all select 4, concat_ws('|', 'LEFT', 'auth.users', count(*)) from auth.users where id = current_setting('kd.t_uid')::uuid
  union all select 5, concat_ws('|', 'LEFT', 'auth.audit_log_entries', count(*)) from auth.audit_log_entries where payload::text like '%' || current_setting('kd.t_uid') || '%'
  union all select 6, concat_ws('|', 'OTHERS', count(*) || '|' || split_part(current_setting('kd.t_others'), '|', 2)) from public.kodhane_progress_log
     where user_id <> current_setting('kd.t_uid')::uuid and id <= split_part(current_setting('kd.t_others'), '|', 2)::bigint
) x order by o;
