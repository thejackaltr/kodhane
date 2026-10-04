-- PARTIAL of supabase/ops/kodhane_score_rule_install.sh (build -> preflight.sql, READ ONLY). Target and prerequisites.
select concat_ws('|', 'INFO', 'target', current_database(), current_user, 'server ' || current_setting('server_version'));
select case when to_regclass('public.kodhane_saves') is null or to_regclass('auth.users') is null then 'STOP: wrong target (no public.kodhane_saves / auth.users)'
            when to_regclass('public.fenomen_saves') is not null then 'STOP: wrong target (public.fenomen_saves exists: Fenomen database)'
            else 'INFO|target_kodhane|t' end;
select concat_ws('|', 'INFO', 'current_rule', left(coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '-'), 60),
                 md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure)));
select case when coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') like 'Kodhane leaderboard heuristic v4.4b %'
              or coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') like 'Kodhane leaderboard heuristic v4.5 %'
            then 'INFO|package_b|t' else 'STOP: package B (kodhane_score_plausible v4.4b) is not installed here: install B first' end;
select case when exists (select 1 from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgname = 'kodhane_saves_a_version_guard' and tgenabled = 'O')
            then 'INFO|b_version_guard|enabled' else 'STOP: B version guard trigger kodhane_saves_a_version_guard missing or disabled' end;
select concat_ws('|', 'INFO', 'kodhane_rule_schema', coalesce(to_regnamespace('kodhane_rule')::text, 'absent (fresh install)'));
select concat_ws('|', 'INFO', 'saves_by_format', coalesce(string_agg(f || ':' || n, ',' order by f), '-'))
  from (select coalesce(greatest(case when jsonb_typeof(data -> 'saveVersion') = 'number' then (data ->> 'saveVersion')::numeric end,
                                 case when jsonb_typeof(data -> 'version') = 'number' then (data ->> 'version')::numeric end)::text, '?') as f, count(*) as n
          from public.kodhane_saves group by 1) x;
