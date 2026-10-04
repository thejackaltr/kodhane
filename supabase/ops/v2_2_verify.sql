-- v2.2 post-migration verification (writes nothing but a session temp table).
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v2_2_verify.sql
-- Prints n|check|ok|detail (every ok must be t) and ends with "VERIFY OK: n/n". Any failed check -> ERROR, exit 3.
-- Checks marked [right after] describe the state right after the migrations (before clients write): run it then.
-- The player-data fingerprint is separate (v2_2_fingerprint.sql; diff against the preflight output).
\set ON_ERROR_STOP on
\pset footer off
set client_min_messages = warning;
create temp table if not exists v22_verify (n int primary key, check_name text, ok boolean, detail text);
truncate v22_verify;

-- helpers for the expectations (independent of the migration's own functions; spec: best_score = totalEarned of a
-- save that is plausible at migration time, else 0; best_stage = its data.stage clamped to 0..99 (Kodhane: only if the
-- stage is believable for totalEarned), else 0)
create or replace function pg_temp.v22_score(d jsonb) returns numeric language sql immutable as $$
  select case when jsonb_typeof(d -> 'totalEarned') = 'number' and (d ->> 'totalEarned')::numeric between 0 and 1.7976931348623157e308
              then (d ->> 'totalEarned')::numeric else 0 end $$;
create or replace function pg_temp.v22_stage(d jsonb) returns int language sql immutable as $$
  select case when jsonb_typeof(d -> 'stage') = 'number' then least(99, greatest(0, floor((d ->> 'stage')::numeric)))::int else 0 end $$;

with t(n, check_name, ok, detail) as (
  select 1, 'kodhane_saves: revision, best_score, best_stage, strict_revision columns',
         count(*) = 4, string_agg(attname, ',' order by attname)
    from pg_attribute where attrelid = 'public.kodhane_saves'::regclass and not attisdropped
     and attname in ('revision', 'best_score', 'best_stage', 'strict_revision')
  union all
  select 2, 'acik_ofis_saves: revision, best_score, best_stage, strict_revision columns',
         count(*) = 4, string_agg(attname, ',' order by attname)
    from pg_attribute where attrelid = 'public.acik_ofis_saves'::regclass and not attisdropped
     and attname in ('revision', 'best_score', 'best_stage', 'strict_revision')
  union all
  select 3, 'write/delete triggers on both save tables', count(*) = 4, string_agg(tgname, ',' order by tgname)
    from pg_trigger where not tgisinternal and tgname in ('kodhane_saves_before_write', 'kodhane_saves_before_delete',
                                                         'acik_ofis_saves_before_write', 'acik_ofis_saves_before_delete')
  union all
  select 4, 'new tables', count(*) filter (where to_regclass(x) is not null) = 5, string_agg(x || '=' || (to_regclass(x) is not null), ',')
    from unnest(array['public.kodhane_save_backups', 'public.kodhane_game_config', 'public.acik_ofis_save_backups',
                      'public.acik_ofis_game_config', 'public.acik_ofis_profiles']) x
  union all
  select 5, 'RPCs exist', count(*) filter (where to_regprocedure(x) is not null) = 9,
         coalesce(string_agg(x, ',') filter (where to_regprocedure(x) is null), 'all 9')
    from unnest(array['public.kodhane_reset_save()', 'public.kodhane_restore_save(uuid)', 'public.kodhane_list_save_backups()',
                      'public.acik_ofis_reset_save()', 'public.acik_ofis_restore_save(uuid)', 'public.acik_ofis_list_save_backups()',
                      'public.acik_ofis_leaderboard(integer)', 'public.kodhane_cleanup_save_backups()', 'public.acik_ofis_cleanup_save_backups()']) x
  union all
  select 6, 'EXECUTE: authenticated yes, anon no (reset/restore/list RPCs)',
         bool_and(has_function_privilege('authenticated', x, 'execute') and not has_function_privilege('anon', x, 'execute')), string_agg(x, ',')
    from unnest(array['public.kodhane_reset_save()', 'public.kodhane_restore_save(uuid)', 'public.kodhane_list_save_backups()',
                      'public.acik_ofis_reset_save()', 'public.acik_ofis_restore_save(uuid)', 'public.acik_ofis_list_save_backups()']) x
  union all
  select 7, 'EXECUTE kodhane_leaderboard for anon + authenticated',
         has_function_privilege('anon', 'public.kodhane_leaderboard(integer,text)', 'execute')
         and has_function_privilege('authenticated', 'public.kodhane_leaderboard(integer,text)', 'execute'), null
  union all
  select 8, 'no DELETE grant and no delete policy on the save tables',
         bool_and(not has_table_privilege(r, tb, 'delete')) and not exists (select 1 from pg_policies where tablename in ('kodhane_saves', 'acik_ofis_saves') and cmd in ('DELETE', 'ALL')),
         (select coalesce(string_agg(policyname, ','), 'no delete policy') from pg_policies where tablename in ('kodhane_saves', 'acik_ofis_saves') and cmd in ('DELETE', 'ALL'))
    from unnest(array['anon', 'authenticated']) r, unnest(array['public.kodhane_saves', 'public.acik_ofis_saves']) tb
  union all
  select 9, 'clients cannot write best_score/best_stage/strict_revision; can write revision',
         bool_and(not has_column_privilege('authenticated', tb, c, 'insert') and not has_column_privilege('authenticated', tb, c, 'update'))
         and has_column_privilege('authenticated', 'public.kodhane_saves', 'revision', 'update')
         and has_column_privilege('authenticated', 'public.acik_ofis_saves', 'revision', 'update'), null
    from unnest(array['public.kodhane_saves', 'public.acik_ofis_saves']) tb, unnest(array['best_score', 'best_stage', 'strict_revision']) c
  union all
  select 10, 'anon: no access to save/backup tables',
         bool_and(not has_table_privilege('anon', tb, 'select') and not has_table_privilege('anon', tb, 'insert') and not has_table_privilege('anon', tb, 'update')), null
    from unnest(array['public.kodhane_saves', 'public.acik_ofis_saves', 'public.kodhane_save_backups', 'public.acik_ofis_save_backups']) tb
  union all
  select 11, 'kodhane_leaderboard is v6 (comment + body), NOT the Açık Ofis shim',
         cmt like '%v6 (Kodhane v2.2 migration 20260928160000)%' and cmt not like '%shim%'
         and def like '%s.data, s.best_score, s.best_stage%' and def not like '%EXACTLY kodhane-cloud/leaderboard.v5.sql%',
         left(cmt, 60)
    from (select coalesce(obj_description('public.kodhane_leaderboard(integer,text)'::regprocedure, 'pg_proc'), '') cmt,
                 pg_get_functiondef('public.kodhane_leaderboard(integer,text)'::regprocedure) def) x
  union all
  select 12, 'revision_mode = lenient for both games (until the separate strict step)',
         (select value from public.kodhane_game_config where key = 'revision_mode') = '"lenient"'
         and (select value from public.acik_ofis_game_config where key = 'revision_mode') = '"lenient"',
         (select value::text from public.kodhane_game_config where key = 'revision_mode') || '/' ||
         (select value::text from public.acik_ofis_game_config where key = 'revision_mode')
  union all
  select 13, 'acik_ofis_score_plausible still exists (owned by the Açık Ofis file)',
         to_regprocedure('public.acik_ofis_score_plausible(jsonb,timestamptz)') is not null, null
)
insert into v22_verify select * from t;

-- backfill: 0 rows expected. Migration time T = first run of each file (config rows are never overwritten).
with k as (
  select s.*, (select updated_at from public.kodhane_game_config where key = 'backup_retention_days') t0 from public.kodhane_saves s
), ke as (
  select k.*, case when pg_temp.v22_score(data) > 0 and coalesce(public.kodhane_score_plausible(data, t0), false) then pg_temp.v22_score(data) else 0 end e_score,
         case when pg_temp.v22_stage(data) between 1 and 8 and pg_temp.v22_score(data) > 0
                   and pg_temp.v22_score(data) >= ('{0,1e3,5e4,1e6,5e7,2.5e9,1e15,1e19,1e23}'::numeric[])[pg_temp.v22_stage(data) + 1]
                   and coalesce(public.kodhane_score_plausible(data, t0), false) then pg_temp.v22_stage(data) else 0 end e_stage
    from k
), kbad as (
  -- never below the value at migration time; untouched rows (revision 0, lenient) exactly equal
  select * from ke where best_score < e_score or best_stage < e_stage
      or (revision = 0 and not strict_revision and (best_score <> e_score or best_stage <> e_stage))
)
insert into v22_verify select 14, 'backfill kodhane_saves: best_score/best_stage = expected (rows off)', count(*) = 0,
       count(*) || ' off of ' || (select count(*) from public.kodhane_saves) || coalesce(': ' || string_agg(user_id::text, ',' order by user_id) filter (where true), '')
  from (select * from kbad limit 20) x;

with a as (
  select s.*, (select updated_at from public.acik_ofis_game_config where key = 'backup_retention_days') t0 from public.acik_ofis_saves s
), ae as (
  select a.*, case when pg_temp.v22_score(data) > 0 and coalesce(public.acik_ofis_score_plausible(data, t0), false) then pg_temp.v22_score(data) else 0 end e_score,
         case when pg_temp.v22_stage(data) > 0 and pg_temp.v22_score(data) > 0 and coalesce(public.acik_ofis_score_plausible(data, t0), false)
              then pg_temp.v22_stage(data) else 0 end e_stage
    from a
), abad as (
  select * from ae where best_score < e_score or best_stage < e_stage
      or (revision = 0 and not strict_revision and (best_score <> e_score or best_stage <> e_stage))
)
insert into v22_verify select 15, 'backfill acik_ofis_saves: best_score/best_stage = expected (rows off)', count(*) = 0,
       count(*) || ' off of ' || (select count(*) from public.acik_ofis_saves) || coalesce(': ' || string_agg(user_id::text, ',' order by user_id) filter (where true), '')
  from (select * from abad limit 20) x;

-- informational (always ok): Kodhane list rows (v5 'ok' rows: profile, not hidden, plausible current save) whose shown
-- stage changes v5 -> v6: v5 showed the raw data.stage (null if not a number), v6 shows the vetted best_stage
insert into v22_verify
select 16, 'info: Kodhane list rows whose stage changes v5 -> v6 (stage not believable for the score, or not a number)', true, count(*)::text
  from public.kodhane_saves s join public.kodhane_profiles p on p.user_id = s.user_id
 where not p.hidden and jsonb_typeof(s.data -> 'totalEarned') = 'number'
   and (s.data ->> 'totalEarned')::numeric between 0 and 1.7976931348623157e308
   and coalesce(public.kodhane_score_plausible(s.data), false)
   and (case when jsonb_typeof(s.data -> 'stage') = 'number' then pg_temp.v22_stage(s.data) end) is distinct from s.best_stage;

insert into v22_verify
select 17, '[right after] every row lenient with revision 0, no backups yet',
       not exists (select 1 from public.kodhane_saves where revision <> 0 or strict_revision)
       and not exists (select 1 from public.acik_ofis_saves where revision <> 0 or strict_revision)
       and not exists (select 1 from public.kodhane_save_backups) and not exists (select 1 from public.acik_ofis_save_backups),
       (select count(*) from public.kodhane_saves where strict_revision) || ' kodhane strict, ' ||
       (select count(*) from public.acik_ofis_saves where strict_revision) || ' acik_ofis strict';
insert into v22_verify
select 18, '[right after] acik_ofis_profiles mirrors kodhane_profiles for every Açık Ofis player (not used by the v2.2 client yet)',
       count(*) = 0, count(*) || ' missing'
  from public.acik_ofis_saves s join public.kodhane_profiles p on p.user_id = s.user_id
 where not exists (select 1 from public.acik_ofis_profiles q where q.user_id = s.user_id and q.nickname = p.nickname);

\pset format unaligned
select n, check_name, ok, coalesce(detail, '') from v22_verify order by n;
do $v$
declare bad text;
begin
  select string_agg(n::text, ',') into bad from v22_verify where not ok;
  if bad is not null then raise exception 'VERIFY FAILED: checks %', bad; end if;
end $v$;
select format('VERIFY OK: %s/%s', count(*), count(*)) from v22_verify;
drop table v22_verify;
