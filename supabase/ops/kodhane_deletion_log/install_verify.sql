-- Deletion log install check (READ ONLY; migration 20261003040000). Used by ops/kodhane_deletion_log_install.sh in the
-- dry run, the install transaction (before COMMIT) and the verify step. Prints CHECK|name|t/f|detail lines and
-- DLVERIFY|PASS; any f -> exception (the install transaction rolls back).
select string_agg('CHECK|' || c.name || '|' || case when c.ok then 't' else 'f' end || '|' || c.detail, E'\n' order by c.ord) as dl_lines,
       coalesce(bool_and(c.ok), false) as dl_ok,
       coalesce(string_agg(c.name, ', ' order by c.ord) filter (where not c.ok), '') as dl_failed
  from (
  select 1 as ord, 'schema' as name, coalesce((select nspowner::regrole::text = 'postgres' from pg_namespace where nspname = 'kodhane_private'), false) as ok,
         'kodhane_private owner ' || coalesce((select nspowner::regrole::text from pg_namespace where nspname = 'kodhane_private'), 'MISSING') as detail
  union all
  select 2, 'schema_acl', to_regnamespace('kodhane_private') is not null
         and not has_schema_privilege('anon', 'kodhane_private', 'USAGE') and not has_schema_privilege('authenticated', 'kodhane_private', 'USAGE')
         and not has_schema_privilege('service_role', 'kodhane_private', 'USAGE') and not has_schema_privilege('anon', 'kodhane_private', 'CREATE')
         and not has_schema_privilege('authenticated', 'kodhane_private', 'CREATE') and not has_schema_privilege('service_role', 'kodhane_private', 'CREATE'),
         'no USAGE / CREATE for anon, authenticated, service_role; acl ' || coalesce((select nspacl::text from pg_namespace where nspname = 'kodhane_private'), '-')
  union all
  select 3, 'table', coalesce((select relowner::regrole::text = 'postgres' from pg_class where oid = to_regclass('kodhane_private.deletion_log')), false),
         'kodhane_private.deletion_log owner ' || coalesce((select relowner::regrole::text from pg_class where oid = to_regclass('kodhane_private.deletion_log')), 'MISSING')
  union all
  select 4, 'columns', coalesce((select string_agg(attname || ' ' || format_type(atttypid, atttypmod) || case when attnotnull then ' not null' else '' end, ', ' order by attnum)
           from pg_attribute where attrelid = to_regclass('kodhane_private.deletion_log') and attnum > 0 and not attisdropped), '')
         = 'user_id uuid not null, scope text not null, deleted_at timestamp with time zone not null, approval_ref text not null',
         coalesce((select string_agg(attname || ' ' || format_type(atttypid, atttypmod), ', ' order by attnum)
           from pg_attribute where attrelid = to_regclass('kodhane_private.deletion_log') and attnum > 0 and not attisdropped), 'MISSING') || ' (no e-mail column)'
  union all
  select 5, 'constraints', coalesce((select string_agg(conname || '=' || pg_get_constraintdef(oid), ' ; ' order by conname)
           from pg_constraint where conrelid = to_regclass('kodhane_private.deletion_log')), '')
         = 'deletion_log_approval_ref_check=CHECK ((approval_ref ~ ''^(self|info|purge):[^@,"\\[:cntrl:]]{1,200}$''::text)) ; deletion_log_pkey=PRIMARY KEY (user_id, scope) ; deletion_log_scope_check=CHECK ((scope = ANY (ARRAY[''account''::text, ''kodhane''::text])))',
         'PK (user_id, scope); scope account | kodhane; approval_ref (self|info|purge):<no @ , " \ control>'
  union all
  select 6, 'rls', coalesce((select relrowsecurity and relforcerowsecurity from pg_class where oid = to_regclass('kodhane_private.deletion_log')), false)
         and not exists (select 1 from pg_policy where polrelid = to_regclass('kodhane_private.deletion_log')),
         'RLS enabled + forced, ' || (select count(*) from pg_policy where polrelid = to_regclass('kodhane_private.deletion_log')) || ' policies'
  union all
  select 7, 'table_acl', to_regclass('kodhane_private.deletion_log') is not null and not exists (
           select 1 from unnest(array['anon', 'authenticated', 'service_role']) r(role),
                         unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p(priv)
            where has_table_privilege(r.role, 'kodhane_private.deletion_log', p.priv)),
         'no privilege for anon, authenticated, service_role; acl ' || coalesce((select relacl::text from pg_class where oid = to_regclass('kodhane_private.deletion_log')), '-')
  union all
  select 8, 'index', exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
           where i.indrelid = to_regclass('kodhane_private.deletion_log') and c.relname = 'deletion_log_deleted_at_idx'), 'deletion_log_deleted_at_idx (deleted_at)'
  union all
  select 9, 'functions', coalesce((select string_agg(p.oid::regprocedure::text || ' ' || p.proowner::regrole::text || ' ' || coalesce(p.proacl::text, 'NULL')
           || ' ' || coalesce(array_to_string(p.proconfig, ','), ''), ' ; ' order by p.proname) from pg_proc p where p.pronamespace = to_regnamespace('kodhane_private')), '')
         = 'kodhane_private.cfg_deletion_log_retention() postgres {postgres=X/postgres} search_path="" ; kodhane_private.cleanup_deletion_log() postgres {postgres=X/postgres} search_path=""',
         'cfg_deletion_log_retention(), cleanup_deletion_log(): owner postgres, EXECUTE postgres only, search_path ''''; '
         || coalesce((select count(*)::text from pg_proc p where p.pronamespace = to_regnamespace('kodhane_private')), '0') || ' function(s) in the schema'
  union all
  select 10, 'retention', to_regprocedure('kodhane_private.cfg_deletion_log_retention()') is not null
         and coalesce((select prosrc from pg_proc where oid = to_regprocedure('kodhane_private.cfg_deletion_log_retention()')), '') = ' select interval ''45 days'' ',
         'cfg_deletion_log_retention() = 45 days (Kodhane save backups 30 days + 15 days margin; DB backups ~14 days)'
  union all
  select 11, 'cleanup_src', coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('kodhane_private.cleanup_deletion_log()')), '') = '767bc92b3e6f104e47dfbb73bd8c9a4c',
         'cleanup_deletion_log() source md5 ' || coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('kodhane_private.cleanup_deletion_log()')), 'MISSING')
  union all
  select 12, 'postgres_bypassrls', coalesce((select rolbypassrls from pg_roles where rolname = 'postgres'), false),
         'role postgres BYPASSRLS (owner reads / cleans the forced-RLS table; the Dokploy retention command runs as postgres)'
  ) c
\gset
\echo :dl_lines
\if :dl_ok
  \echo 'DLVERIFY|PASS'
\else
  \echo 'DLVERIFY|FAIL|' :dl_failed
  do $$ begin raise exception 'kodhane deletion log install check failed'; end $$;
\endif
