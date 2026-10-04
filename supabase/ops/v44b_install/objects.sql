-- PARTIAL of supabase/ops/kodhane_v44b_install.sh: one OBJ line per Kodhane object that B or the progress log creates or
-- changes (every public.kodhane* function, the triggers / columns / constraints of kodhane_saves and kodhane_progress_log).
-- md5 values only; the install script diffs these lines (preflight -> dry-run = new objects; dry-run = install = verify).
select concat_ws('|', 'OBJ', 'FN', p.oid::regprocedure::text, 'def=' || md5(pg_get_functiondef(p.oid)),
                 'secdef=' || p.prosecdef, 'owner=' || pg_get_userbyid(p.proowner), 'acl=' || md5(coalesce(p.proacl::text, '')),
                 'comment=' || md5(coalesce(obj_description(p.oid, 'pg_proc'), '')))
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'kodhane%' order by p.oid::regprocedure::text;
select concat_ws('|', 'OBJ', 'TRG', t.tgrelid::regclass::text, t.tgname, 'enabled=' || t.tgenabled::text, 'def=' || md5(pg_get_triggerdef(t.oid)))
  from pg_trigger t where t.tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname in ('kodhane_saves', 'kodhane_progress_log'))
   and not t.tgisinternal order by t.tgrelid::regclass::text, t.tgname;
select concat_ws('|', 'OBJ', 'COL', a.attrelid::regclass::text, a.attname, format_type(a.atttypid, a.atttypmod), 'notnull=' || a.attnotnull,
                 'default=' || md5(coalesce(pg_get_expr(d.adbin, d.adrelid), '')), 'acl=' || md5(coalesce(a.attacl::text, '')))
  from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
 where a.attrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname in ('kodhane_saves', 'kodhane_progress_log'))
   and a.attnum > 0 and not a.attisdropped order by a.attrelid::regclass::text, a.attnum;
select concat_ws('|', 'OBJ', 'CON', c.conrelid::regclass::text, c.conname, 'def=' || md5(pg_get_constraintdef(c.oid)))
  from pg_constraint c where c.conrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname in ('kodhane_saves', 'kodhane_progress_log'))
 order by c.conrelid::regclass::text, c.conname;
select concat_ws('|', 'OBJ', 'REL', c.oid::regclass::text, 'kind=' || c.relkind::text, 'rls=' || c.relrowsecurity, 'owner=' || pg_get_userbyid(c.relowner),
                 'acl=' || md5(coalesce(c.relacl::text, '')))
  from pg_class c where c.relnamespace = 'public'::regnamespace and (c.relname in ('kodhane_saves', 'kodhane_progress_log')
        or c.oid in (select indexrelid from pg_index where indrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname = 'kodhane_progress_log')))
 order by c.oid::regclass::text;
select concat_ws('|', 'OBJ', 'POL', schemaname || '.' || tablename, policyname, md5(concat_ws(';', cmd, roles::text, qual, with_check)))
  from pg_policies where schemaname = 'public' and tablename in ('kodhane_saves', 'kodhane_progress_log') order by tablename, policyname;
