-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (step delete-path-check, READ ONLY, after the install): shows from the
-- catalog that every account-deletion path removes a user's public.kodhane_progress_log rows.
--   * auth.users delete (GoTrue admin delete, or mode=full of ops/kodhane_account_delete.sql): FK ON DELETE CASCADE
--     (pg_constraint confdeltype = 'c').
--   * mode=kodhane_only: an explicit DELETE in the ops file ops/kodhane_account_delete.sql (not a DB function); the
--     script checks that file's md5 and the statement next to this query.
--   * no DB function deletes auth.users (account deletion is an ops file); the functions touching the log are listed.
-- Prints INFO lines and CHECK|delpath_n|t/f, then DELPATH_SQL|PASS or DELPATH_SQL|FAIL.
select concat_ws('|', 'INFO', 'fk_to_auth_users', c.conrelid::regclass::text, c.conname, 'confdeltype=' || c.confdeltype::text,
                 'def=' || pg_get_constraintdef(c.oid))
  from pg_constraint c where c.contype = 'f' and c.confrelid = 'auth.users'::regclass and c.connamespace = 'public'::regnamespace
 order by c.conrelid::regclass::text, c.conname;
select concat_ws('|', 'INFO', 'fn_mentions_progress_log', p.oid::regprocedure::text, 'def=' || md5(pg_get_functiondef(p.oid)),
                 'deletes_rows=' || (p.prosrc ~* 'delete\s+from\s+public\.kodhane_progress_log'))
  from pg_proc p where p.prosrc like '%kodhane_progress_log%' order by p.oid::regprocedure::text;
select concat_ws('|', 'INFO', 'fn_deletes_auth_users', n.nspname || '.' || p.oid::regprocedure::text, 'def=' || md5(pg_get_functiondef(p.oid)))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where p.prosrc ~* 'delete\s+from\s+auth\.users' and n.nspname not in ('pg_catalog', 'information_schema') order by n.nspname, p.proname;
select concat_ws('|', 'INFO', 'fn_reset_restore', p.oid::regprocedure::text, 'def=' || md5(pg_get_functiondef(p.oid)),
                 'touches_progress_log=' || (p.prosrc like '%kodhane_progress_log%'))
  from pg_proc p where p.oid in (to_regprocedure('public.kodhane_reset_save()'), to_regprocedure('public.kodhane_restore_save(uuid)'))
 order by p.proname;
with c(n, name, ok) as (
  select 1, 'kodhane_progress_log.user_id -> auth.users(id) ON DELETE CASCADE (confdeltype c)',
    exists (select 1 from pg_constraint where conrelid = to_regclass('public.kodhane_progress_log') and contype = 'f'
              and confrelid = 'auth.users'::regclass and confdeltype = 'c'
              and conkey = array[(select attnum from pg_attribute where attrelid = 'public.kodhane_progress_log'::regclass and attname = 'user_id')]::int2[])
  union all select 2, 'no other foreign key on kodhane_progress_log (nothing can block the cascade)',
    (select count(*) from pg_constraint where conrelid = to_regclass('public.kodhane_progress_log') and contype = 'f') = 1
  union all select 3, 'log trigger fires on INSERT / UPDATE of kodhane_saves only (a save DELETE writes no log row)',
    (select pg_get_triggerdef(oid) from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgname = 'kodhane_saves_z_progress_log')
      like 'CREATE TRIGGER kodhane_saves_z_progress_log AFTER INSERT OR UPDATE ON public.kodhane_saves FOR EACH ROW %'
  union all select 4, 'no trigger on kodhane_progress_log, no RLS policy, anon / authenticated cannot read or delete rows',
    not exists (select 1 from pg_trigger where tgrelid = to_regclass('public.kodhane_progress_log') and not tgisinternal)
    and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'kodhane_progress_log')
    and not has_table_privilege('anon', 'public.kodhane_progress_log', 'select,delete')
    and not has_table_privilege('authenticated', 'public.kodhane_progress_log', 'select,delete')
  union all select 5, 'no DB function deletes auth.users (account deletion = ops file ops/kodhane_account_delete.sql)',
    not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where p.prosrc ~* 'delete\s+from\s+auth\.users' and n.nspname not in ('pg_catalog', 'information_schema'))
  union all select 6, 'only kodhane_cleanup_progress_log deletes log rows (retention); kodhane_reset_save / _restore_save do not touch the log',
    (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p where p.prosrc ~* 'delete\s+from\s+public\.kodhane_progress_log')
      = array['kodhane_cleanup_progress_log(integer,integer)']
    and not exists (select 1 from pg_proc p where p.oid in (to_regprocedure('public.kodhane_reset_save()'), to_regprocedure('public.kodhane_restore_save(uuid)'))
                     and p.prosrc like '%kodhane_progress_log%')
)
select l from (
  select n, concat_ws('|', 'CHECK', 'delpath_' || n, coalesce(ok, false), name) as l from c
  union all select 99, concat_ws('|', 'DELPATH_SQL', case when bool_and(coalesce(ok, false)) and count(*) = 6 then 'PASS' else 'FAIL' end) from c
) x order by n;
