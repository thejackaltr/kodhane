-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (build -> preflight.sql). READ ONLY. Package B + progress log install,
-- step 2 (docs/kodhane-v44b-install-runbook.md). Prints INFO|... lines (counts only: no user id, nickname, e-mail, save
-- content), then raises 'STOP: ...' listing every unexpected condition, else prints PREFLIGHT|PASS.
-- B rule (20260929204000): a player write whose data.saveVersion is lower than the STORED data.saveVersion, while the
-- stored save is v4.4 format (saveVersion >= 5), is refused with PT426. Format <= 4 saves are not guarded.
select concat_ws('|', 'INFO', 'target', current_database(), current_user, split_part(version(), ' ', 2),
                 to_char(now() at time zone 'Europe/Istanbul', 'YYYY-MM-DD HH24:MI:SS') || ' TSİ');
-- saves by stored format -> what B does to the owner's next write from an old client
select concat_ws('|', 'INFO', 'saves_by_stored_format', fmt, count(*),
                 count(*) filter (where updated_at > now() - interval '1 day'), count(*) filter (where updated_at > now() - interval '7 days'),
                 case fmt when 'sv>=5' then 'v4.4 format: after B a v4.3.x / older client write is REFUSED (PT426), v4.4 client ok'
                          when 'sv1-4' then 'format 4: not guarded, every client may write (guarded once a v4.4 client saved)'
                          when 'no_sv' then 'oldest format (no saveVersion): not guarded (guarded once a v4.4 client saved)'
                          else 'saveVersion present but not a number: counts as 0, not guarded' end)
  from (select updated_at,
               case when not (data ? 'saveVersion') or jsonb_typeof(data -> 'saveVersion') = 'null' then 'no_sv'
                    when jsonb_typeof(data -> 'saveVersion') <> 'number' then 'sv_not_number'
                    when (data ->> 'saveVersion')::numeric >= 5 then 'sv>=5'
                    else 'sv1-4' end as fmt
          from public.kodhane_saves) x
 group by fmt order by fmt;
select concat_ws('|', 'INFO', 'saves_columns', 'total=' || count(*),
                 'with_clientVersion=' || count(*) filter (where data ? 'clientVersion'),
                 'with_stageId=' || count(*) filter (where data ? 'stageId'),
                 'sv_gt_5=' || count(*) filter (where jsonb_typeof(data -> 'saveVersion') = 'number' and (data ->> 'saveVersion')::numeric > 5))
  from public.kodhane_saves;
select concat_ws('|', 'INFO', 'client_versions_seen', cv, count(*))
  from (select coalesce(left(data ->> 'clientVersion', 32), '(none)') as cv from public.kodhane_saves) x group by cv order by cv;
select concat_ws('|', 'INFO', 'other_objects',
                 'audit_log_retention=' || (to_regprocedure('public.kodhane_cleanup_audit_log(integer)') is not null),
                 'acik_ofis_saves=' || (to_regclass('public.acik_ofis_saves') is not null),
                 'pg_cron=' || exists (select 1 from pg_extension where extname = 'pg_cron'));
select concat_ws('|', 'INFO', 'sessions_on_db', count(*), 'idle_in_tx=' || count(*) filter (where state like 'idle in transaction%'))
  from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid();

do $preflight$
declare
  problems text[] := '{}';
  a_md5 text;
  trg text[];
begin
  if to_regclass('public.kodhane_saves') is null or to_regprocedure('public.kodhane_leaderboard(integer,text)') is null
     or to_regclass('auth.users') is null or to_regclass('public.kodhane_save_backups') is null then
    raise exception 'STOP: wrong target (not the shared Teserix game database %)', current_database();
  end if;
  if current_user <> 'supabase_admin' then problems := problems || format('current_user is %s, not supabase_admin', current_user); end if;
  if not exists (select 1 from pg_attribute where attrelid = 'public.kodhane_saves'::regclass and attname = 'revision' and not attisdropped) then
    problems := problems || 'Kodhane v2.2 (revision column) missing'::text;
  end if;
  -- package A exactly as installed on 2026-10-01 20:39 TSİ
  a_md5 := md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure));
  if a_md5 <> '969e1dc203fa1877a57e2cf3fcc2727c' then
    problems := problems || format('kodhane_score_plausible md5(functiondef) %s, expected A 969e1dc203fa1877a57e2cf3fcc2727c', a_md5);
  end if;
  -- package B absent
  if to_regprocedure('public.kodhane_leaderboard_v7(integer)') is not null or to_regprocedure('public.kodhane_save_version_guard()') is not null
     or to_regprocedure('public.kodhane_save_v44_stage_id()') is not null or to_regprocedure('public.kodhane_stage_rank(text)') is not null
     or exists (select 1 from pg_attribute where attrelid = 'public.kodhane_saves'::regclass and attname = 'best_stage_id' and not attisdropped) then
    problems := problems || 'package B (or part of it) already present'::text;
  end if;
  -- progress log absent
  if to_regclass('public.kodhane_progress_log') is not null or to_regprocedure('public.kodhane_progress_log_write()') is not null
     or to_regprocedure('public.kodhane_cleanup_progress_log(integer,integer)') is not null then
    problems := problems || 'progress log (or part of it) already present'::text;
  end if;
  -- kodhane_saves carries exactly the two v2.2 triggers, enabled
  select array_agg(tgname::text || ':' || tgenabled::text order by tgname) into trg
    from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and not tgisinternal;
  if trg is distinct from array['kodhane_saves_before_delete:O', 'kodhane_saves_before_write:O'] then
    problems := problems || format('unexpected triggers on kodhane_saves: %s', trg);
  end if;
  -- the verify step inserts a synthetic auth user inside a rolled-back transaction: no trigger may fire on auth.users
  if exists (select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and not tgisinternal) then
    problems := problems || 'auth.users has triggers (verify would fire them)'::text;
  end if;
  if exists (select 1 from auth.users where id = 'b44b0000-0000-4000-8000-00000000c0de') then
    problems := problems || 'synthetic verify user id b44b0000-...-c0de exists'::text;
  end if;
  -- a stored saveVersion above 5 would make B refuse every v4.4 (saveVersion 5) write of that account
  if exists (select 1 from public.kodhane_saves where jsonb_typeof(data -> 'saveVersion') = 'number' and (data ->> 'saveVersion')::numeric > 5) then
    problems := problems || 'saves with saveVersion > 5 exist (v4.4 writes of those accounts would get PT426)'::text;
  end if;
  if exists (select 1 from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid()
              and state like 'idle in transaction%' and xact_start < now() - interval '5 minutes') then
    problems := problems || 'a session is idle in transaction for more than 5 minutes (would block the install lock)'::text;
  end if;
  if cardinality(problems) > 0 then
    raise exception 'STOP: %', array_to_string(problems, '; ');
  end if;
end $preflight$;
