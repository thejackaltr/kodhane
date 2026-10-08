-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (dry-run / install): structural checks after the migrations, same
-- transaction. Prints CHECK|name|t lines; any failure aborts the whole transaction (nothing installed).
create temp table _kd_v44b_post on commit drop as
with c(n, name, ok) as (
  select 1, 'kodhane_score_plausible is v4.4b (B), same answer as A for every stored save',
    coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') like 'Kodhane leaderboard heuristic v4.4b %'
    and not exists (select 1 from public.kodhane_saves s join _kd_v44b_plaus_before b using (user_id)
                     where public.kodhane_score_plausible(s.data) is distinct from b.ok)
    and (select count(*) from public.kodhane_saves) = (select count(*) from _kd_v44b_plaus_before)
  union all select 2, 'kodhane_saves triggers: B guard + stage id, v2.2 x2, progress log; all enabled',
    (select array_agg(tgname::text || ':' || tgenabled::text order by tgname) from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and not tgisinternal)
      = array['kodhane_saves_a_version_guard:O', 'kodhane_saves_before_delete:O', 'kodhane_saves_before_write:O',
              'kodhane_saves_v44_stage_id:O', 'kodhane_saves_z_progress_log:O']
  union all select 3, 'B guard rule (sv_new < sv_old and sv_old >= 5), SECURITY INVOKER; best_stage_id column + constraint',
    (select prosrc from pg_proc where oid = 'public.kodhane_save_version_guard()'::regprocedure) like '%if sv_new < sv_old and sv_old >= 5 then%'
    and not (select prosecdef from pg_proc where oid = 'public.kodhane_save_version_guard()'::regprocedure)
    and exists (select 1 from pg_constraint where conrelid = 'public.kodhane_saves'::regclass and conname = 'kodhane_saves_best_stage_id_known')
  union all select 4, 'kodhane_leaderboard_v7: anon + authenticated execute',
    has_function_privilege('anon', 'public.kodhane_leaderboard_v7(integer)', 'execute')
    and has_function_privilege('authenticated', 'public.kodhane_leaderboard_v7(integer)', 'execute')
  union all select 5, 'kodhane_progress_log: RLS on, no anon / authenticated privilege, service_role SELECT only, empty',
    (select relrowsecurity from pg_class where oid = 'public.kodhane_progress_log'::regclass)
    and not has_table_privilege('anon', 'public.kodhane_progress_log', 'select,insert,update,delete')
    and not has_table_privilege('authenticated', 'public.kodhane_progress_log', 'select,insert,update,delete')
    and has_table_privilege('service_role', 'public.kodhane_progress_log', 'select')
    and not has_table_privilege('service_role', 'public.kodhane_progress_log', 'insert,update,delete')
    and not exists (select 1 from public.kodhane_progress_log)
  union all select 6, 'kodhane_cleanup_progress_log: execute postgres + service_role only; trigger function SECURITY DEFINER owner postgres',
    has_function_privilege('service_role', 'public.kodhane_cleanup_progress_log(integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.kodhane_cleanup_progress_log(integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.kodhane_cleanup_progress_log(integer,integer)', 'execute')
    and (select prosecdef and pg_get_userbyid(proowner) = 'postgres' from pg_proc where oid = 'public.kodhane_progress_log_write()'::regprocedure)
  union all select 7, 'stored data untouched: no best_stage_id backfill',
    not exists (select 1 from public.kodhane_saves where best_stage_id is not null)
)
select n, name, ok from c;
select concat_ws('|', 'CHECK', 'post_' || n, ok, name) from _kd_v44b_post order by n;
do $post$
begin
  if exists (select 1 from _kd_v44b_post where ok is not true) then
    raise exception 'STOP: post-migration check(s) failed: %', (select string_agg(n::text, ',' order by n) from _kd_v44b_post where ok is not true);
  end if;
end $post$;
