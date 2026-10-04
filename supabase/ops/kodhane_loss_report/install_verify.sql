-- Kodhane loss report (Kayıp bildir, migration 20261003060000): install check. READ ONLY, writes nothing.
--   psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -f supabase/ops/kodhane_loss_report/install_verify.sql
-- Prints CHECK|<name>|t|f|<detail> lines and LRVERIFY|PASS|<n> or LRVERIFY|FAIL|<failed checks>; any f -> ERROR (exit code 3).
\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on
begin transaction read only;
with c(ord, name, ok, detail) as (
  select 1, 'prerequisites',
         exists (select 1 from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgname = 'kodhane_saves_a_version_guard' and tgenabled = 'O')
         and exists (select 1 from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgname = 'kodhane_saves_z_progress_log' and tgenabled = 'O'),
         'B version guard + progress log trigger enabled'
  union all
  select 2, 'table_owner_rls',
         coalesce((select relowner::regrole::text || '|' || relrowsecurity || '|' || relforcerowsecurity || '|' || (select count(*) from pg_policy p where p.polrelid = c.oid)
                     from pg_class c where c.oid = to_regclass('kodhane_loss.loss_report')), 'MISSING') = 'postgres|true|true|0',
         coalesce((select relowner::regrole::text || '|' || relrowsecurity || '|' || relforcerowsecurity from pg_class where oid = to_regclass('kodhane_loss.loss_report')), 'MISSING')
           || ' (owner | RLS | FORCE), no policy'
  union all
  select 3, 'no_api_privilege',
         to_regclass('kodhane_loss.loss_report') is not null
         and (select count(*) filter (where has_table_privilege(r, 'kodhane_loss.loss_report', p))
                from unnest(array['anon', 'authenticated', 'service_role', 'public']) r, unnest(array['select', 'insert', 'update', 'delete', 'truncate', 'references', 'trigger']) p) = 0
         and (select count(*) filter (where has_sequence_privilege(r, pg_get_serial_sequence('kodhane_loss.loss_report', 'id'), p))
                from unnest(array['anon', 'authenticated', 'service_role', 'public']) r, unnest(array['usage', 'select', 'update']) p) = 0
         and (select count(*) filter (where has_schema_privilege(r, 'kodhane_loss', p))
                from unnest(array['anon', 'authenticated', 'service_role', 'public']) r, unnest(array['usage', 'create']) p) = 0,
         'table, sequence, schema: nothing for anon / authenticated / service_role / public'
  union all
  select 4, 'columns_no_email',
         coalesce((select string_agg(attname, ',' order by attnum) from pg_attribute where attrelid = to_regclass('kodhane_loss.loss_report') and attnum > 0 and not attisdropped), '')
         = 'id,user_id,created_at,lost_items,lost_since,description,client_version,save_revision,status,status_changed_at,approval_ref,ref_at,approved_values,approved_revision,approved_at,plausible_before,plausible_after,reject_reason,ops_note,decided_by,review_count,review_reason,applied_at,applied_rev_before,applied_rev_after,applied_diff,backup_id',
         '27 columns, uid only (no e-mail / nickname)'
  union all
  select 5, 'constraints',
         coalesce((select string_agg(conname, ',' order by conname) from pg_constraint where conrelid = to_regclass('kodhane_loss.loss_report') and contype in ('c', 'u', 'f')), '')
         = 'loss_report_approval_ref_check,loss_report_approval_ref_key,loss_report_client_version_check,loss_report_description_check,loss_report_lost_items_check,loss_report_ops_note_check,loss_report_reject_reason_check,loss_report_review_reason_check,loss_report_state_check,loss_report_status_check,loss_report_user_id_fkey'
         and exists (select 1 from pg_constraint where conrelid = to_regclass('kodhane_loss.loss_report') and conname = 'loss_report_user_id_fkey'
                     and confdeltype = 'c' and confrelid = 'auth.users'::regclass)
         and coalesce(pg_get_indexdef(to_regclass('kodhane_loss.loss_report_one_open_idx')), '') =
             'CREATE UNIQUE INDEX loss_report_one_open_idx ON kodhane_loss.loss_report USING btree (user_id) WHERE (status = ANY (ARRAY[''pending''::text, ''approved''::text, ''needs_review''::text]))',
         'CHECKs, unique approval_ref, FK auth.users ON DELETE CASCADE, one open report per player'
  union all
  select 6, 'player_rpcs',
         (select count(*) from pg_proc p where p.oid in (to_regprocedure('public.kodhane_loss_report_create(text[],timestamptz,text,text)'), to_regprocedure('public.kodhane_loss_report_status(integer)'))
             and p.prosecdef and p.proowner::regrole::text = 'postgres' and array_to_string(p.proconfig, ',') = 'search_path=""'
             and p.proacl::text = '{postgres=X/postgres,authenticated=X/postgres}') = 2,
         'create + status: SECURITY DEFINER, owner postgres, search_path '''', EXECUTE postgres + authenticated only'
  union all
  select 7, 'ops_functions',
         (select count(*) from pg_proc p where p.pronamespace = to_regnamespace('kodhane_loss')
             and (p.proname like 'loss\_report%' or p.proname in ('cfg_loss_report', 'cleanup_loss_reports'))
             and not p.prosecdef and p.proowner::regrole::text = 'postgres' and array_to_string(p.proconfig, ',') = 'search_path=""'
             and p.proacl::text = '{postgres=X/postgres}') = 14
         and (select count(*) from pg_proc p where p.pronamespace = to_regnamespace('kodhane_loss')
             and (p.proname like 'loss\_report%' or p.proname in ('cfg_loss_report', 'cleanup_loss_reports'))) = 14,
         '14 functions: owner postgres, not SECURITY DEFINER, search_path '''', EXECUTE postgres only'
  union all
  select 8, 'config',
         to_regprocedure('kodhane_loss.cfg_loss_report()') is not null
         and coalesce((select kodhane_loss.cfg_loss_report() @> '{"per_24h": 1, "per_30_days": 5, "description_max": 280, "lost_since_max_days": 365, "lost_since_future_minutes": 5, "retention_months": 12, "review_reasons": ["save_changed", "no_cloud_save"]}'
                        where to_regprocedure('kodhane_loss.cfg_loss_report()') is not null), false),
         '1 / 24 h, 5 / 30 days, description 280, lost_since 365 days back / 5 min ahead, retention 12 months'
  union all
  select 9, 'player_status_columns',
         coalesce(pg_get_function_result(to_regprocedure('public.kodhane_loss_report_status(integer)')), '')
         = 'TABLE(id bigint, created_at timestamp with time zone, lost_items text[], lost_since timestamp with time zone, status text, status_changed_at timestamp with time zone, reason text, applied_at timestamp with time zone, review_reason text, applied_revision bigint)'
         and coalesce((select pg_get_constraintdef(oid) from pg_constraint where conrelid = to_regclass('kodhane_loss.loss_report') and conname = 'loss_report_review_reason_check'), '')
             = 'CHECK (((review_reason IS NULL) OR (review_reason = ANY (ARRAY[''save_changed''::text, ''no_cloud_save''::text]))))',
         'status RPC columns (no ops field; applied_revision last) + review_reason CHECK: save_changed | no_cloud_save | NULL'
)
select string_agg('CHECK|' || name || '|' || case when ok then 't' else 'f' end || '|' || detail, E'\n' order by ord) as lr_lines,
       coalesce(bool_and(ok), false) as lr_ok, coalesce(string_agg(name, ',' order by ord) filter (where not ok), '') as lr_failed, count(*) as lr_n
  from c \gset
\echo :lr_lines
\if :lr_ok
  \echo LRVERIFY|PASS|:lr_n
\else
  \echo LRVERIFY|FAIL|:lr_failed
  do $f$ begin raise exception 'kodhane loss report install verify FAILED'; end $f$;
\endif
rollback;
