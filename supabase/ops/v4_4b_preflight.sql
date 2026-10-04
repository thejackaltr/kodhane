-- Kodhane v4.4 PACKAGE B preflight (READ ONLY): right database? A applied? B already applied? and what the save-version
-- guard will do to the stored saves (counts only, no user id / nickname / e-mail).
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v4_4b_preflight.sql
\set ON_ERROR_STOP on
begin read only;
do $pre$
begin
  if to_regclass('public.kodhane_saves') is null or to_regprocedure('public.kodhane_leaderboard(integer,text)') is null then
    raise exception 'WRONG TARGET: not the shared Teserix game DB';
  end if;
  raise notice 'target ok: db=%, user=%; package A: %; package B: %', current_database(), current_user,
    case when coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') like 'Kodhane leaderboard heuristic v4.4a %'
         then 'applied (expected)'
         when coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') like 'Kodhane leaderboard heuristic v4.4b %'
         then 'applied (kodhane_score_plausible already v4.4b from B)' else 'NOT APPLIED -> apply A first' end,
    case when to_regprocedure('public.kodhane_leaderboard_v7(integer)') is not null then 'ALREADY APPLIED' else 'not applied (expected)' end;
end $pre$;
-- stored save format (data.saveVersion; missing = 0) -> which clients the guard refuses for that account
select sv as stored_save_version, count(*) as saves,
       case when sv >= 5 then 'v4.4 format: v4.3.1 / v4.3.0 / older writes refused (426)'
            else 'not guarded (format <= 4): every client may write' end as effect
  from (select case when jsonb_typeof(data -> 'saveVersion') = 'number'
                    then least(1000000, greatest(0, floor((data ->> 'saveVersion')::numeric)))::int else 0 end as sv
          from public.kodhane_saves) x group by 1, 3 order by 1;
-- saves already carrying v4.4 stage IDs (v4.4 client); best_stage distribution (read via the legacy list after B)
select count(*) filter (where data ? 'stageId') as saves_with_stage_id,
       count(*) filter (where data->>'stageId' in ('unicorn', 'sirketler_grubu')) as on_unicorn_or_sirketler_grubu,
       count(*) filter (where best_stage = 5) as best_stage_global_holding
  from public.kodhane_saves;
commit;
