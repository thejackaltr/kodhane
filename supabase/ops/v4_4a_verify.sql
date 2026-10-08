-- Kodhane v4.4 PACKAGE A verify (READ ONLY) after the migration: prints one row per check, all must be 't'.
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v4_4a_verify.sql
\set ON_ERROR_STOP on
begin read only;
with f as (
  select p.oid, p.prosrc, l.lanname, p.provolatile, p.proparallel, p.prosecdef, p.proconfig, p.proowner::regrole::text as owner,
         p.proacl::text as acl, pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as res,
         pg_get_expr(p.proargdefaults, 0) as defaults, coalesce(obj_description(p.oid, 'pg_proc'), '') as cmt
  from pg_proc p join pg_language l on l.oid = p.prolang
  where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure
), c(n, name, ok) as (
  select 1, 'v4.4a definition in place (comment + sql body marker)', cmt like 'Kodhane leaderboard heuristic v4.4a %' and lanname = 'sql' and prosrc like '%v4.4a%' from f
  union all select 2, 'signature / result / default unchanged', args = 'd jsonb, p_now timestamp with time zone' and res = 'boolean' and defaults = 'now()' from f
  union all select 3, 'STABLE PARALLEL SAFE, not SECURITY DEFINER, search_path ''''', provolatile = 's' and proparallel = 's' and not prosecdef and proconfig = array['search_path=""'] from f
  union all select 4, 'owner postgres, EXECUTE only postgres + service_role (as before)', owner = 'postgres' and acl = '{postgres=X/postgres,service_role=X/postgres}' from f
  union all select 5, 'anon / authenticated cannot execute', not has_function_privilege('anon', (select oid from f), 'execute') and not has_function_privilege('authenticated', (select oid from f), 'execute')
  union all select 6, 'callers unchanged (v2.2 vetted score / stage, leaderboard v6)',
    to_regprocedure('public.kodhane_save_vetted_score(jsonb)') is not null and to_regprocedure('public.kodhane_save_vetted_stage(jsonb)') is not null
    and coalesce(obj_description('public.kodhane_leaderboard(integer,text)'::regprocedure, 'pg_proc'), '') like '%v6 (Kodhane v2.2 migration 20260928160000)%'
  union all select 7, 'smoke: honest v4.3 fresh save true, 1e30 fresh save false, non-object false',
    public.kodhane_score_plausible(jsonb_build_object('version', 4, 'totalEarned', 5000, 'runEarned', 5000, 'startedAt', extract(epoch from now()) * 1000 - 3600000))
    and not public.kodhane_score_plausible(jsonb_build_object('version', 4, 'totalEarned', 1e30, 'runEarned', 1e30, 'startedAt', extract(epoch from now()) * 1000 - 60000))
    and not coalesce(public.kodhane_score_plausible('[1]'::jsonb), false)
)
select n, name, ok from c order by n;
select count(*) as saves, count(*) filter (where public.kodhane_score_plausible(data)) as plausible_v4_4a from public.kodhane_saves;
commit;
