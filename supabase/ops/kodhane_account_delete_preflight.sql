-- Kodhane manual account deletion, step A: PREFLIGHT (READ ONLY; writes nothing).
-- Lists every row of one auth user, table by table and per game (Kodhane, Açık Ofis), what each mode would do with it,
-- and the expect token the delete needs (covers the rows of BOTH games + id, e-mail, created_at of the auth user).
-- public.kodhane_progress_log (if the table exists) is listed and deleted in both modes but NOT part of the token: it grows
-- with every save write, so a player who keeps playing would otherwise invalidate the token again and again.
-- kodhane_loss.loss_report (Kayıp bildir, migration 20261003060000; if installed) is listed, deleted in both modes and IS
-- part of the token (a new report after the preflight = run the preflight again).
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -v uid=<auth user id> -f supabase/ops/kodhane_account_delete_preflight.sql
-- Runbook: docs/kodhane-account-delete-runbook.md. Output has no e-mail in clear (masked) and no nickname.
\set ON_ERROR_STOP on
\if :{?uid}
\else
  \echo 'kodhane account delete preflight: pass -v uid=<auth user id>'
  do $$ begin raise exception 'uid missing'; end $$;
\endif
begin transaction read only;
select set_config('kodhane_del.uid', (:'uid')::uuid::text, true) is not null as uid_ok;

-- 1. target: right database? does the auth user exist? (e-mail masked)
select current_database() as db, current_user as db_user,
       exists (select 1 from auth.users u where u.id = current_setting('kodhane_del.uid')::uuid) as auth_user_exists,
       (select left(u.email, 1) || '***@' || split_part(u.email, '@', 2) from auth.users u where u.id = current_setting('kodhane_del.uid')::uuid) as email_masked,
       (select u.created_at from auth.users u where u.id = current_setting('kodhane_del.uid')::uuid) as auth_created_at,
       (select u.last_sign_in_at from auth.users u where u.id = current_setting('kodhane_del.uid')::uuid) as last_sign_in_at,
       (select string_agg(distinct i.provider, ',') from auth.identities i where i.user_id = current_setting('kodhane_del.uid')::uuid) as providers;

-- 2. rows per table, grouped: kodhane | acik_ofis | auth | audit | other, and what each mode does with them
select * from (
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

-- 3. per game: backups by reason, leaderboard state (no nickname)
select 'kodhane' as game, b.reason, count(*) as n, max(b.best_score) as max_best_score
  from public.kodhane_save_backups b where b.user_id = current_setting('kodhane_del.uid')::uuid group by 1, 2
union all
select 'acik_ofis', b.reason, count(*), max(b.best_score)
  from public.acik_ofis_save_backups b where b.user_id = current_setting('kodhane_del.uid')::uuid group by 1, 2
order by 1, 2;
select 'kodhane' as game, s.best_score, s.best_stage, p.user_id is not null as has_profile, coalesce(p.hidden, false) as hidden,
       (p.user_id is not null and not coalesce(p.hidden, false) and s.best_score > 0) as listed
  from public.kodhane_saves s left join public.kodhane_profiles p on p.user_id = s.user_id
 where s.user_id = current_setting('kodhane_del.uid')::uuid
union all
select 'acik_ofis', s.best_score, s.best_stage, ap.user_id is not null or kp.user_id is not null,
       coalesce(ap.hidden, false) or coalesce(kp.hidden, false),
       ((ap.user_id is not null and not coalesce(ap.hidden, false)) or (kp.user_id is not null and not coalesce(kp.hidden, false))) and s.best_score > 0
  from public.acik_ofis_saves s
  left join public.acik_ofis_profiles ap on ap.user_id = s.user_id
  left join public.kodhane_profiles kp on kp.user_id = s.user_id
 where s.user_id = current_setting('kodhane_del.uid')::uuid;

-- 4. verdict per mode + expect token (pass it to the delete as -v expect=<token>, together with -v mode=...)
select case when not x.user_exists then 'STOP: auth user not found'
            when x.blocked is not null then 'BLOCKED: rows outside Kodhane / Açık Ofis (' || x.blocked || ') would be cascaded'
            else 'OK: deletes Kodhane ' || x.kod || ' + Açık Ofis ' || x.ao || ' + audit ' || x.audit || ' rows + the auth user' end as mode_full,
       case when not x.user_exists then 'STOP: auth user not found'
            else 'OK: deletes ' || x.kod_only || ' Kodhane rows (saves, backups, progress log, carry) + closes ' || x.sess || ' sessions / refresh tokens; keeps kodhane_profiles, auth user, audit, Açık Ofis ('
                 || x.ao || ' rows)' end as mode_kodhane_only,
       x.token as expect
  from (select left(md5(coalesce(string_agg(x.rel || '=' || x.n, ' ' order by x.rel) filter (where x.cat in ('kodhane', 'acik_ofis', 'other') and x.rel <> 'public.kodhane_progress_log'), '')
                         || ' auth=' ||
  -- <kodhane_del_identity>  (identical in preflight / delete; part of the expect token: id, e-mail, created_at of the auth
  -- user; NOT last_sign_in_at, sessions or audit rows, which change with every login / token refresh)
  coalesce((select u.id::text || '|' || coalesce(u.email, '') || '|' || coalesce(extract(epoch from u.created_at)::text, '')
              from auth.users u where u.id = current_setting('kodhane_del.uid')::uuid), 'no auth user')
  -- </kodhane_del_identity>
                        ), 12) as token,
               string_agg(x.rel || '=' || x.n, ', ' order by x.rel) filter (where x.act_full = 'block' and x.n > 0) as blocked,
               coalesce(sum(x.n) filter (where x.cat = 'kodhane'), 0) as kod,
               coalesce(sum(x.n) filter (where x.cat = 'kodhane' and x.act_kodhane_only = 'delete'), 0) as kod_only,
               coalesce(sum(x.n) filter (where x.rel in ('auth.sessions', 'auth.refresh_tokens')), 0) as sess,
               coalesce(sum(x.n) filter (where x.cat = 'acik_ofis'), 0) as ao,
               coalesce(sum(x.n) filter (where x.cat = 'audit'), 0) as audit,
               coalesce(sum(x.n) filter (where x.rel = 'auth.users'), 0) = 1 as user_exists
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
          ) x) x;
rollback;
