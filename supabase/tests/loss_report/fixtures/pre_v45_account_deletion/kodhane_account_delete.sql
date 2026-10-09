-- Kodhane manual account deletion, step B: DELETE (one transaction; any error = nothing deleted).
-- ONLY after Aryen's written approval for THIS uid and THIS mode (runbook step 3). Run as supabase_admin / postgres, never with -1.
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v mode=<full|kodhane_only> -v uid=<auth user id> -v confirm_uid=<same id again> \
--        -v approval_ref=<approval reference, no personal data> -v expect=<token from the preflight> \
--        -f supabase/ops/kodhane_account_delete.sql
-- mode=full (whole account, both games), explicit DELETEs, all before the auth user:
--   1 kodhane_saves (trigger writes a 'delete' copy) -> 2 all kodhane_save_backups of the user (incl. that copy; otherwise a
--   re-created row starts from the old best score) -> 3 kodhane_profiles (+ kodhane_event_log_carry,
--   kodhane_progress_log if they exist)
--   -> 4 acik_ofis_saves (trigger copy) -> acik_ofis_save_backups (incl. the copy) -> acik_ofis_profiles -> any other
--   acik_ofis_* row -> 5 auth.audit_log_entries (payload.actor_id / payload.traits.user_id) -> 6 auth.refresh_tokens,
--   auth.flow_state, auth.users (identities, sessions ... cascade) -> check: 0 rows left, audit included.
-- mode=kodhane_only (Kodhane data only): 1 kodhane_saves -> 2 kodhane_save_backups -> 3 kodhane_event_log_carry and
--   kodhane_progress_log (progress log) if they exist
--   -> 4 every session of the user (auth.refresh_tokens, auth.sessions). Keeps auth user, kodhane_profiles (Açık Ofis
--   nickname), audit log, Açık Ofis. The Kodhane leaderboards (v6, v7) join
--   kodhane_saves, so the user drops out of them; the Açık Ofis leaderboards do not change.
-- Deletion log (silme listesi, migration 20261003040000, installed separately from package B): when
--   kodhane_private.deletion_log exists, the delete writes (uid, scope = account | kodhane, now(), 'info:<approval_ref>')
--   into it IN THIS TRANSACTION (first row of a uid + scope stays). After a DB restore
--   ops/kodhane_deletion_log_reapply.sh deletes the listed uids again with THIS file's DO block (no expect token there;
--   only uid + scope pairs that are in the list). Without the table the delete works as before (no list row).
-- Refuses (nothing deleted) when: mode missing / unknown, confirm_uid differs, approval_ref empty or with @ , " \ or a
-- control character (it goes into the deletion log, no e-mail addresses there), auth user missing,
-- rows of either game or the auth user's id / e-mail / created_at changed since the preflight (expect), or (full) rows
-- outside Kodhane / Açık Ofis would be cascaded.
\set ON_ERROR_STOP on
\if :{?mode}
\else
  \set mode ''
\endif
\if :{?uid}
\else
  \echo 'kodhane account delete: pass -v uid=<auth user id>'
  do $$ begin raise exception 'uid missing'; end $$;
\endif
\if :{?confirm_uid}
\else
  \echo 'kodhane account delete: pass -v confirm_uid=<the same auth user id>'
  do $$ begin raise exception 'confirm_uid missing'; end $$;
\endif
\if :{?approval_ref}
\else
  \echo 'kodhane account delete: pass -v approval_ref=<approval reference>'
  do $$ begin raise exception 'approval_ref missing'; end $$;
\endif
\if :{?expect}
\else
  \echo 'kodhane account delete: pass -v expect=<token printed by the preflight>'
  do $$ begin raise exception 'expect missing'; end $$;
\endif
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
select set_config('kodhane_del.uid', (:'uid')::uuid::text, true) is not null
   and set_config('kodhane_del.mode', :'mode', true) is not null
   and set_config('kodhane_del.confirm_uid', :'confirm_uid', true) is not null
   and set_config('kodhane_del.approval_ref', :'approval_ref', true) is not null
   and set_config('kodhane_del.expect', :'expect', true) is not null as params_ok;
do $del$
declare
  v_uid uuid := current_setting('kodhane_del.uid')::uuid;
  v_mode text := lower(btrim(current_setting('kodhane_del.mode')));
  v_ref text := btrim(current_setting('kodhane_del.approval_ref'));
  v_expect text := btrim(current_setting('kodhane_del.expect'));
  v_reapply boolean := coalesce(current_setting('kodhane_del.reapply', true), '') = 'on';
  v_scope text; v_listed boolean; v_dlog text; n_dlog bigint := 0;
  v_token text; v_blocked text; v_nonkod text; v_left text; v_users bigint; r record;
  n_ks bigint := 0; k_before bigint; k_after bigint; n_kb bigint := 0; n_kp bigint := 0; n_carry bigint := 0;
  n_as bigint := 0; a_before bigint; a_after bigint; n_ab bigint := 0; n_ap bigint := 0; n_ao_other bigint := 0; n bigint;
  n_audit bigint := 0; n_rt bigint := 0; n_fs bigint := 0; n_users bigint := 0; n_sess bigint := 0; n_plog bigint := 0;
begin
  select string_agg(x.rel || '=' || x.n, ', ' order by x.rel) filter (where x.cat in ('acik_ofis', 'other') and x.n > 0)
    into v_nonkod
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
                             'public.kodhane_progress_log', 'auth.sessions', 'auth.refresh_tokens') then 'delete'
              else 'keep' end as act_kodhane_only
    from (
      select distinct
             case when n.nspname = 'public' and c.relname like 'kodhane\_%' then 'kodhane'
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
  if v_mode = '' then
    raise exception 'kodhane account delete BLOCKED: mode missing (-v mode=full | kodhane_only); nothing deleted%',
      coalesce('. Non-Kodhane rows: ' || v_nonkod || ' (full deletes them, kodhane_only keeps them)', '');
  elsif v_mode not in ('full', 'kodhane_only') then
    raise exception 'kodhane account delete: unknown mode "%" (full | kodhane_only); nothing deleted', v_mode;
  end if;
  if btrim(current_setting('kodhane_del.confirm_uid')) is distinct from v_uid::text then
    raise exception 'kodhane account delete: confirm_uid does not match uid; nothing deleted';
  end if;
  if length(v_ref) < 4 then
    raise exception 'kodhane account delete: approval_ref (Aryen''s approval reference) is required; nothing deleted';
  end if;
  if length(v_ref) > 200 or v_ref ~ '[@,"\\[:cntrl:]]' then
    raise exception 'kodhane account delete: approval_ref must be at most 200 characters without @ , " \ or control characters (it is written to the deletion log; no e-mail address); nothing deleted';
  end if;
  v_scope := case v_mode when 'full' then 'account' else 'kodhane' end;
  perform 1 from auth.users u where u.id = v_uid for update;          -- blocks concurrent client writes (FK key share)
  if not found then
    raise exception 'kodhane account delete: auth user % not found; nothing deleted (run the verify)', v_uid;
  end if;
  perform 1 from public.kodhane_saves s where s.user_id = v_uid for update;
  perform 1 from public.acik_ofis_saves s where s.user_id = v_uid for update;

  select left(md5(coalesce(string_agg(x.rel || '=' || x.n, ' ' order by x.rel) filter (where x.cat in ('kodhane', 'acik_ofis', 'other') and x.rel <> 'public.kodhane_progress_log'), '')
                  || ' auth=' ||
  -- <kodhane_del_identity>  (identical in preflight / delete; part of the expect token: id, e-mail, created_at of the auth
  -- user; NOT last_sign_in_at, sessions or audit rows, which change with every login / token refresh)
  coalesce((select u.id::text || '|' || coalesce(u.email, '') || '|' || coalesce(extract(epoch from u.created_at)::text, '')
              from auth.users u where u.id = current_setting('kodhane_del.uid')::uuid), 'no auth user')
  -- </kodhane_del_identity>
                 ), 12),
         string_agg(x.rel || '=' || x.n, ', ' order by x.rel) filter (where x.act_full = 'block' and x.n > 0)
    into v_token, v_blocked
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
                             'public.kodhane_progress_log', 'auth.sessions', 'auth.refresh_tokens') then 'delete'
              else 'keep' end as act_kodhane_only
    from (
      select distinct
             case when n.nspname = 'public' and c.relname like 'kodhane\_%' then 'kodhane'
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
  if v_mode = 'full' and v_blocked is not null then
    raise exception 'kodhane account delete BLOCKED: rows outside Kodhane / Açık Ofis (%) would be cascaded with the auth user. Nothing deleted', v_blocked;
  end if;
  if v_reapply then
    -- deletion log reapply (ops/kodhane_deletion_log_reapply.sh, after a restore): no preflight token, but only for a
    -- uid + scope that is in kodhane_private.deletion_log (the reapply writes the list rows first, same transaction)
    if to_regclass('kodhane_private.deletion_log') is null then
      raise exception 'kodhane account delete (reapply): kodhane_private.deletion_log does not exist; nothing deleted';
    end if;
    execute 'select exists (select 1 from kodhane_private.deletion_log d where d.user_id = $1 and d.scope = $2)'
      into v_listed using v_uid, v_scope;
    if not v_listed then
      raise exception 'kodhane account delete (reapply): uid + scope % not in the deletion log; nothing deleted', v_scope;
    end if;
  elsif v_token is distinct from v_expect then
    raise exception 'kodhane account delete: rows or account (id / e-mail / created_at) changed since the preflight (expect %, now %); run the preflight again. Nothing deleted', v_expect, v_token;
  end if;

  -- K1. Kodhane save row; the BEFORE DELETE trigger (kodhane_saves_before_delete, depth 1) writes a reason = 'delete' backup
  select count(*) into k_before from public.kodhane_save_backups b where b.user_id = v_uid and b.reason = 'delete';
  delete from public.kodhane_saves s where s.user_id = v_uid;
  get diagnostics n_ks = row_count;
  select count(*) into k_after from public.kodhane_save_backups b where b.user_id = v_uid and b.reason = 'delete';
  if k_after - k_before <> n_ks then
    raise exception 'kodhane account delete step 1: expected % Kodhane ''delete'' copy(ies) from the trigger, found %; rolled back', n_ks, k_after - k_before;
  end if;
  -- K2. every Kodhane backup of the user, including the copy K1 just wrote
  delete from public.kodhane_save_backups b where b.user_id = v_uid;
  get diagnostics n_kb = row_count;
  -- K3. event-log carry, if that table exists (the counts refuse when it exists without user_id)
  if to_regclass('public.kodhane_event_log_carry') is not null then
    execute 'delete from public.kodhane_event_log_carry where user_id = $1' using v_uid;
    get diagnostics n_carry = row_count;
  end if;
  -- K3b. progress log (kazanç günlüğü, migration 20261003020000), if the table exists. After K1: the save row is gone, so no
  --      new log row can appear; the log is not part of the expect token (it grows with every save write).
  if to_regclass('public.kodhane_progress_log') is not null then
    execute 'delete from public.kodhane_progress_log where user_id = $1' using v_uid;
    get diagnostics n_plog = row_count;
  end if;

  if v_mode = 'kodhane_only' then
    -- K4. close every session of the user: refresh tokens (FK-less user_id) first, then sessions (mfa_amr_claims and any
    --     session-bound refresh token cascade). The auth user stays; an access JWT already issued stays valid until it expires.
    delete from auth.refresh_tokens t where t.user_id = v_uid::text;
    get diagnostics n_rt = row_count;
    delete from auth.sessions s where s.user_id = v_uid;
    get diagnostics n_sess = row_count;
  end if;

  if v_mode = 'full' then
    -- K4. Kodhane profile (nickname: the Kodhane leaderboard row, also the Açık Ofis nickname in kodhane_leaderboard)
    delete from public.kodhane_profiles p where p.user_id = v_uid;
    get diagnostics n_kp = row_count;
    -- A1. Açık Ofis cloud save; acik_ofis_saves_before_delete writes a 'delete' copy
    select count(*) into a_before from public.acik_ofis_save_backups b where b.user_id = v_uid and b.reason = 'delete';
    delete from public.acik_ofis_saves s where s.user_id = v_uid;
    get diagnostics n_as = row_count;
    select count(*) into a_after from public.acik_ofis_save_backups b where b.user_id = v_uid and b.reason = 'delete';
    if a_after - a_before <> n_as then
      raise exception 'kodhane account delete step A1: expected % Açık Ofis ''delete'' copy(ies) from the trigger, found %; rolled back', n_as, a_after - a_before;
    end if;
    -- A2. every Açık Ofis backup (incl. that copy), A3. Açık Ofis profile (acik_ofis_leaderboard row), A4. any other acik_ofis_* row
    delete from public.acik_ofis_save_backups b where b.user_id = v_uid;
    get diagnostics n_ab = row_count;
    delete from public.acik_ofis_profiles p where p.user_id = v_uid;
    get diagnostics n_ap = row_count;
    for r in select format('%I.%I', c.relnamespace::regnamespace::text, c.relname) as rel from pg_catalog.pg_class c
              where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname like 'acik\_ofis\_%'
                and c.relname not in ('acik_ofis_saves', 'acik_ofis_save_backups', 'acik_ofis_profiles')
                and exists (select 1 from pg_catalog.pg_attribute a where a.attrelid = c.oid and a.attname = 'user_id' and not a.attisdropped)
              order by 1 loop
      execute format('delete from %s where user_id = $1', r.rel) using v_uid;
      get diagnostics n = row_count;
      n_ao_other := n_ao_other + n;
    end loop;
    -- X1. GoTrue audit log entries of the user (no user column: payload.actor_id / payload.traits.user_id)
    delete from auth.audit_log_entries e
     where e.payload ->> 'actor_id' = v_uid::text or e.payload -> 'traits' ->> 'user_id' = v_uid::text;
    get diagnostics n_audit = row_count;
    -- X2. auth user; identities, sessions (-> refresh tokens, mfa claims), mfa factors, one-time tokens ... cascade.
    --     refresh_tokens.user_id and flow_state.user_id have no FK: deleted explicitly.
    delete from auth.refresh_tokens t where t.user_id = v_uid::text;
    get diagnostics n_rt = row_count;
    delete from auth.flow_state f where f.user_id = v_uid;
    get diagnostics n_fs = row_count;
    delete from auth.users u where u.id = v_uid;
    get diagnostics n_users = row_count;
    if n_users <> 1 then
      raise exception 'kodhane account delete step X2: auth.users deleted % rows, expected 1; rolled back', n_users;
    end if;
  end if;

  -- check: every table the mode deletes (or cascades) has 0 rows of the user; kodhane_only: the auth user is still there
  select string_agg(x.rel || '=' || x.n, ', ' order by x.rel)
           filter (where x.n > 0 and case v_mode when 'full' then x.act_full else x.act_kodhane_only end in ('delete', 'cascade', 'block')),
         coalesce(sum(x.n) filter (where x.rel = 'auth.users'), 0)
    into v_left, v_users
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
                             'public.kodhane_progress_log', 'auth.sessions', 'auth.refresh_tokens') then 'delete'
              else 'keep' end as act_kodhane_only
    from (
      select distinct
             case when n.nspname = 'public' and c.relname like 'kodhane\_%' then 'kodhane'
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
    raise exception 'kodhane account delete (%): rows left after the delete (%); rolled back', v_mode, v_left;
  end if;
  if v_mode = 'kodhane_only' and v_users <> 1 then
    raise exception 'kodhane account delete (kodhane_only): the auth user is gone; rolled back';
  end if;
  -- L. deletion log (migration 20261003040000), if installed: same transaction as the delete; the first row of a
  --    uid + scope stays (on conflict do nothing). No e-mail, no nickname: uid, scope, time, approval reference.
  if to_regclass('kodhane_private.deletion_log') is not null then
    execute 'insert into kodhane_private.deletion_log (user_id, scope, approval_ref) values ($1, $2, $3) on conflict (user_id, scope) do nothing'
      using v_uid, v_scope, case when v_ref ~ '^(self|info|purge):' then v_ref else 'info:' || v_ref end;
    get diagnostics n_dlog = row_count;
    v_dlog := case when n_dlog = 1 then 'row written' else 'already listed' end || ' (scope ' || v_scope || ')';
  else
    v_dlog := 'not installed (no row)';
  end if;
  if v_mode = 'full' then
    raise notice 'kodhane account delete OK (mode full, approval %): kodhane_saves %, kodhane delete copies %, kodhane_save_backups % (incl. copies), kodhane_event_log_carry %, kodhane_profiles %, acik_ofis_saves %, acik_ofis delete copies %, acik_ofis_save_backups % (incl. copies), acik_ofis_profiles %, other acik_ofis rows %, audit_log_entries %, auth.refresh_tokens %, auth.flow_state %, auth.users % (+ auth cascades); rows left: 0; kodhane_progress_log %; deletion log %',
      v_ref, n_ks, k_after - k_before, n_kb, n_carry, n_kp, n_as, a_after - a_before, n_ab, n_ap, n_ao_other, n_audit, n_rt, n_fs, n_users, n_plog, v_dlog;
  else
    raise notice 'kodhane account delete OK (mode kodhane_only, approval %): kodhane_saves %, kodhane delete copies %, kodhane_save_backups % (incl. copies), kodhane_event_log_carry %, auth.refresh_tokens %, auth.sessions % (sessions closed); kept: kodhane_profiles, auth user, audit log, Açık Ofis; kodhane_progress_log %; deletion log %',
      v_ref, n_ks, k_after - k_before, n_kb, n_carry, n_rt, n_sess, n_plog, v_dlog;
  end if;
end $del$;
commit;
