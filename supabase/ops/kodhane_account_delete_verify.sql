-- Kodhane manual account deletion, step C: VERIFY (READ ONLY). Use the same mode as the delete.
-- full: every counted table (audit log included) must show 0 rows of the uid. kodhane_only: kodhane_saves,
-- kodhane_save_backups (and kodhane_event_log_carry, kodhane_progress_log, kodhane_loss.loss_report), auth.sessions and auth.refresh_tokens must show 0; the kept rows
-- are listed. Exits non-zero when not.
-- Deletion log (migration 20261003040000): when kodhane_private.deletion_log exists, the uid must be listed with the
-- mode's scope (full = account, kodhane_only = kodhane); without the table the verify says "not installed".
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v mode=<full|kodhane_only> -v uid=<auth user id> -f supabase/ops/kodhane_account_delete_verify.sql
\set ON_ERROR_STOP on
\if :{?mode}
\else
  \echo 'kodhane account delete verify: pass -v mode=full | kodhane_only'
  do $$ begin raise exception 'mode missing'; end $$;
\endif
\if :{?uid}
\else
  \echo 'kodhane account delete verify: pass -v uid=<auth user id>'
  do $$ begin raise exception 'uid missing'; end $$;
\endif
begin transaction read only;
select set_config('kodhane_del.uid', (:'uid')::uuid::text, true) is not null
   and set_config('kodhane_del.mode', lower(btrim(:'mode')), true) in ('full', 'kodhane_only') as params_ok;
select x.cat, x.rel, x.n, case current_setting('kodhane_del.mode') when 'full' then x.act_full else x.act_kodhane_only end as act
  from (
  -- <kodhane_del_counts>  (identical in preflight / delete / verify; the tests check it byte-for-byte)
  -- act_full / act_kodhane_only: what each mode does with the table (delete = explicit DELETE, cascade = goes with
  -- auth.users, keep = stays, block = the delete refuses while n > 0). kodhane_only also closes every session
  -- (auth.sessions + auth.refresh_tokens).
  select t.cat, t.rel, t.col,
         (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from %s where %s', t.rel, t.cond), false, true, '')))[1]::text::bigint as n,
         case when t.cat = 'other' then 'block'
              when t.cat = 'auth' and t.rel not in ('auth.users', 'auth.refresh_tokens', 'auth.flow_state') then 'cascade'
              else 'delete' end as act_full,
         case when t.rel in ('public.kodhane_saves', 'public.kodhane_save_backups', 'public.kodhane_event_log_carry',
                             'public.kodhane_progress_log', 'kodhane_loss.loss_report', 'auth.sessions', 'auth.refresh_tokens') then 'delete'
              else 'keep' end as act_kodhane_only
    from (
      select distinct
             case when n.nspname = 'public' and c.relname like 'kodhane\_%' then 'kodhane'
                  when n.nspname = 'kodhane_loss' and c.relname = 'loss_report' then 'kodhane'   -- Kayıp bildir (20261003060000)
                  when n.nspname = 'public' and c.relname like 'acik\_ofis\_%' then 'acik_ofis'
                  when n.nspname = 'auth' then 'auth'
                  else 'other' end as cat,
             format('%I.%I', n.nspname, c.relname) as rel, a.attname::text as col,
             format('%I = %L', a.attname, current_setting('kodhane_del.uid')) as cond
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
       where c.relkind in ('r', 'p')
         and ((n.nspname = 'public' and (c.relname like 'kodhane\_%' or c.relname like 'acik\_ofis\_%') and a.attname = 'user_id')
           or (n.nspname = 'kodhane_loss' and c.relname = 'loss_report' and a.attname = 'user_id')
           or (n.nspname = 'auth' and c.relname = 'users' and a.attname = 'id')
           or (n.nspname = 'auth' and a.attname = 'user_id')
           or (n.nspname = 'storage' and c.relname = 'objects' and a.attname in ('owner', 'owner_id'))
           or exists (select 1 from pg_catalog.pg_constraint k
                       where k.contype = 'f' and k.conrelid = c.oid and k.confrelid = 'auth.users'::regclass and a.attnum = any (k.conkey)))
      union all   -- kodhane_event_log_carry without a user_id column: unknown layout -> blocker (counts every row)
      select 'other', 'public.kodhane_event_log_carry', '(no user_id column)', 'true'
       where to_regclass('public.kodhane_event_log_carry') is not null
         and not exists (select 1 from pg_catalog.pg_attribute a
                          where a.attrelid = to_regclass('public.kodhane_event_log_carry') and a.attname = 'user_id' and not a.attisdropped)
      union all   -- GoTrue audit log: no user column (instance_id, id, payload json, created_at, ip_address); the user is
                  -- payload.actor_id (own actions) or payload.traits.user_id (admin actions on the user: user_signedup, user_deleted ...)
      select 'audit', 'auth.audit_log_entries', 'payload.actor_id / traits.user_id',
             format('(payload ->> %L = %L or payload -> %L ->> %L = %L)', 'actor_id', current_setting('kodhane_del.uid'),
                    'traits', 'user_id', current_setting('kodhane_del.uid'))
       where to_regclass('auth.audit_log_entries') is not null
    ) t
  -- </kodhane_del_counts>
) x order by case x.cat when 'kodhane' then 1 when 'acik_ofis' then 2 when 'auth' then 3 when 'audit' then 4 else 5 end, x.rel;
do $v$
declare v_left text; v_kept text; v_mode text := current_setting('kodhane_del.mode'); v_dlog text := 'not installed'; v_listed boolean;
begin
  if v_mode not in ('full', 'kodhane_only') then
    raise exception 'kodhane account delete verify: unknown mode "%" (full | kodhane_only)', v_mode;
  end if;
  select string_agg(x.rel || '=' || x.n, ', ' order by x.rel)
           filter (where x.n > 0 and case v_mode when 'full' then x.act_full else x.act_kodhane_only end <> 'keep'),
         string_agg(x.rel || '=' || x.n, ', ' order by x.rel)
           filter (where x.n > 0 and case v_mode when 'full' then x.act_full else x.act_kodhane_only end = 'keep')
    into v_left, v_kept
    from (
  -- <kodhane_del_counts>  (identical in preflight / delete / verify; the tests check it byte-for-byte)
  -- act_full / act_kodhane_only: what each mode does with the table (delete = explicit DELETE, cascade = goes with
  -- auth.users, keep = stays, block = the delete refuses while n > 0). kodhane_only also closes every session
  -- (auth.sessions + auth.refresh_tokens).
  select t.cat, t.rel, t.col,
         (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from %s where %s', t.rel, t.cond), false, true, '')))[1]::text::bigint as n,
         case when t.cat = 'other' then 'block'
              when t.cat = 'auth' and t.rel not in ('auth.users', 'auth.refresh_tokens', 'auth.flow_state') then 'cascade'
              else 'delete' end as act_full,
         case when t.rel in ('public.kodhane_saves', 'public.kodhane_save_backups', 'public.kodhane_event_log_carry',
                             'public.kodhane_progress_log', 'kodhane_loss.loss_report', 'auth.sessions', 'auth.refresh_tokens') then 'delete'
              else 'keep' end as act_kodhane_only
    from (
      select distinct
             case when n.nspname = 'public' and c.relname like 'kodhane\_%' then 'kodhane'
                  when n.nspname = 'kodhane_loss' and c.relname = 'loss_report' then 'kodhane'   -- Kayıp bildir (20261003060000)
                  when n.nspname = 'public' and c.relname like 'acik\_ofis\_%' then 'acik_ofis'
                  when n.nspname = 'auth' then 'auth'
                  else 'other' end as cat,
             format('%I.%I', n.nspname, c.relname) as rel, a.attname::text as col,
             format('%I = %L', a.attname, current_setting('kodhane_del.uid')) as cond
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
       where c.relkind in ('r', 'p')
         and ((n.nspname = 'public' and (c.relname like 'kodhane\_%' or c.relname like 'acik\_ofis\_%') and a.attname = 'user_id')
           or (n.nspname = 'kodhane_loss' and c.relname = 'loss_report' and a.attname = 'user_id')
           or (n.nspname = 'auth' and c.relname = 'users' and a.attname = 'id')
           or (n.nspname = 'auth' and a.attname = 'user_id')
           or (n.nspname = 'storage' and c.relname = 'objects' and a.attname in ('owner', 'owner_id'))
           or exists (select 1 from pg_catalog.pg_constraint k
                       where k.contype = 'f' and k.conrelid = c.oid and k.confrelid = 'auth.users'::regclass and a.attnum = any (k.conkey)))
      union all   -- kodhane_event_log_carry without a user_id column: unknown layout -> blocker (counts every row)
      select 'other', 'public.kodhane_event_log_carry', '(no user_id column)', 'true'
       where to_regclass('public.kodhane_event_log_carry') is not null
         and not exists (select 1 from pg_catalog.pg_attribute a
                          where a.attrelid = to_regclass('public.kodhane_event_log_carry') and a.attname = 'user_id' and not a.attisdropped)
      union all   -- GoTrue audit log: no user column (instance_id, id, payload json, created_at, ip_address); the user is
                  -- payload.actor_id (own actions) or payload.traits.user_id (admin actions on the user: user_signedup, user_deleted ...)
      select 'audit', 'auth.audit_log_entries', 'payload.actor_id / traits.user_id',
             format('(payload ->> %L = %L or payload -> %L ->> %L = %L)', 'actor_id', current_setting('kodhane_del.uid'),
                    'traits', 'user_id', current_setting('kodhane_del.uid'))
       where to_regclass('auth.audit_log_entries') is not null
    ) t
  -- </kodhane_del_counts>
    ) x;
  if v_left is not null then
    raise exception 'kodhane account delete verify (%): rows left for %: %', v_mode, current_setting('kodhane_del.uid'), v_left;
  end if;
  if to_regclass('kodhane_private.deletion_log') is not null then
    execute 'select exists (select 1 from kodhane_private.deletion_log d where d.user_id = $1 and d.scope = $2)' into v_listed
      using current_setting('kodhane_del.uid')::uuid, case v_mode when 'full' then 'account' else 'kodhane' end;
    if not v_listed then
      raise exception 'kodhane account delete verify (%): uid not in kodhane_private.deletion_log (scope %)', v_mode,
        case v_mode when 'full' then 'account' else 'kodhane' end;
    end if;
    v_dlog := 'listed (scope ' || case v_mode when 'full' then 'account' else 'kodhane' end || ')';
  end if;
  raise notice 'kodhane account delete verify OK (%): 0 rows left in the deleted tables; kept: %; deletion log: %', v_mode, coalesce(v_kept, 'nothing'), v_dlog;
end $v$;
rollback;
