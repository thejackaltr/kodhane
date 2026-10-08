-- Kodhane v4.4 PACKAGE B verify (READ ONLY) after the migration: one row per check, all must be 't'.
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v4_4b_verify.sql
\set ON_ERROR_STOP on
begin read only;
with c(n, name, ok) as (
  select 1, 'column kodhane_saves.best_stage_id text + check constraint',
    exists (select 1 from pg_attribute where attrelid = 'public.kodhane_saves'::regclass and attname = 'best_stage_id' and atttypid = 'text'::regtype and not attisdropped)
    and exists (select 1 from pg_constraint where conrelid = 'public.kodhane_saves'::regclass and conname = 'kodhane_saves_best_stage_id_known')
  union all select 2, 'triggers enabled, guard sorts before the v2.2 trigger (progress-log trigger allowed)',
    (select array_agg(tgname::text order by tgname) from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and not tgisinternal and tgenabled = 'O'
        and tgname <> 'kodhane_saves_z_progress_log')
      = array['kodhane_saves_a_version_guard', 'kodhane_saves_before_delete', 'kodhane_saves_before_write', 'kodhane_saves_v44_stage_id']
  union all select 3, 'guard is SECURITY INVOKER (rule: sv_new < sv_old and sv_old >= 5), stage-id trigger SECURITY DEFINER',
    not (select prosecdef from pg_proc where oid = 'public.kodhane_save_version_guard()'::regprocedure)
    and (select prosrc from pg_proc where oid = 'public.kodhane_save_version_guard()'::regprocedure) like '%if sv_new < sv_old and sv_old >= 5 then%'
    and (select prosecdef from pg_proc where oid = 'public.kodhane_save_v44_stage_id()'::regprocedure)
  union all select 4, 'kodhane_leaderboard_v7: anon + authenticated execute; helpers not',
    has_function_privilege('anon', 'public.kodhane_leaderboard_v7(integer)', 'execute') and has_function_privilege('authenticated', 'public.kodhane_leaderboard_v7(integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.kodhane_save_vetted_stage_id(jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.kodhane_save_stage_id_checked(jsonb)', 'execute')
  union all select 5, 'kodhane_leaderboard v6 unchanged; kodhane_score_plausible v4.4b (float8 bounds: extreme save -> false, no 22003)',
    coalesce(obj_description('public.kodhane_leaderboard(integer,text)'::regprocedure, 'pg_proc'), '') like '%v6 (Kodhane v2.2 migration 20260928160000)%'
    and coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') like 'Kodhane leaderboard heuristic v4.4b %'
    and public.kodhane_score_plausible('{"totalEarned": 1e30, "shares": 1e12, "prestigeCount": 10, "cycleRounds": 1, "ipoCount": 1, "ipoSharesEarned": 1e100, "saveVersion": 5}') = false
    and public.kodhane_score_plausible('{"totalEarned": 1.7976931348623157e308, "saveVersion": 5}') = false
  union all select 6, 'v7 = v6 Kodhane list (rank, nickname, score, stage, is_me, status)',
    not exists (select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard_v7(100)
                except all select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard(100, 'kodhane'))
    and not exists (select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard(100, 'kodhane')
                except all select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard_v7(100))
  union all select 7, 'stage catalogue smoke (unicorn rank 6 at 1e11, legacy 5 = global_holding, max picks sirketler_grubu)',
    public.kodhane_stage_rank('unicorn') = 6 and public.kodhane_stage_at('unicorn') = 1e11 and public.kodhane_stage_legacy_id(5) = 'global_holding'
    and public.kodhane_stage_id_max('unicorn', 'global_holding', 'sirketler_grubu') = 'sirketler_grubu' and public.kodhane_save_format_version('{"version": 5}') = 0
)
select n, name, ok from c order by n;
commit;
