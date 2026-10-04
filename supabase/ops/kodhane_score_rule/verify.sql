-- PARTIAL of supabase/ops/kodhane_score_rule_install.sh (build -> verify.sql, READ ONLY, after the install).
-- Prints CHECK|name|t|f lines and SRVERIFY|PASS|n or SRVERIFY|FAIL|n.
begin transaction read only;
with c(n, name, ok) as (
  select 1, 'kodhane_score_plausible is v4.5 (comment) with the reviewed definition (md5 a52586896ae53ac8e5159aa500c4b031)',
    coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') like 'Kodhane leaderboard heuristic v4.5 %'
    and md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure)) = 'a52586896ae53ac8e5159aa500c4b031'
  union all select 2, 'kodhane_score_plausible: LANGUAGE sql, SECURITY INVOKER, owner postgres, EXECUTE only postgres + service_role (as after B)',
    (select l.lanname = 'sql' and not p.prosecdef and pg_get_userbyid(p.proowner) = 'postgres'
            and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute')
            and has_function_privilege('service_role', p.oid, 'execute')
       from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure)
  union all select 3, 'schema kodhane_rule owned by postgres; USAGE only service_role (not anon / authenticated)',
    (select pg_get_userbyid(nspowner) = 'postgres' from pg_namespace where nspname = 'kodhane_rule')
    and has_schema_privilege('service_role', 'kodhane_rule', 'usage')
    and not has_schema_privilege('anon', 'kodhane_rule', 'usage') and not has_schema_privilege('authenticated', 'kodhane_rule', 'usage')
  union all select 4, 'score_curve: owner postgres, RLS on, no table privilege for anon / authenticated / service_role',
    (select pg_get_userbyid(relowner) = 'postgres' and relrowsecurity from pg_class where oid = 'kodhane_rule.score_curve'::regclass)
    and not exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r(r)
                     where has_table_privilege(r.r, 'kodhane_rule.score_curve', 'select,insert,update,delete,truncate'))
  union all select 5, 'active_score_curve(): SECURITY DEFINER, search_path empty, owner postgres, EXECUTE service_role only',
    (select p.prosecdef and p.proconfig = array['search_path=""'] and pg_get_userbyid(p.proowner) = 'postgres'
            and has_function_privilege('service_role', p.oid, 'execute')
            and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute')
       from pg_proc p where p.oid = 'kodhane_rule.active_score_curve()'::regprocedure)
  union all select 6, 'exactly one active row: v45_f2 = GD curve, tier_mult 32 x 1.25^14, ik 0.14/0.15, Borsa cut 0.8',
    (select count(*) = 1 and bool_and(id = 'v45_f2' and growth = '[[0, 1.15], [300, 1.10], [500, 1.05], [1000, 1.025], [3000, 1.0125]]'::jsonb
                                      and tier_mult = 32 * power(1.25::float8, 14) and ik_factor = 0.14::float8 / 0.15 and borsa_cut = 0.8::float8)
       from kodhane_rule.score_curve where active)
  union all select 7, 'helper returns the active row (= dry-run literal of the preflight)',
    (select count(*) = 1 and bool_and(growth = '[[0, 1.15], [300, 1.10], [500, 1.05], [1000, 1.025], [3000, 1.0125]]'::jsonb and tier_mult = 32 * power(1.25::float8, 14))
       from kodhane_rule.active_score_curve())
  union all select 8, 'growth check refuses bad curves (not starting at 0, not increasing, growth <= 1 or > 2, non-integer start)',
    kodhane_rule.score_curve_growth_ok('[[0, 1.15], [300, 1.1]]') and not kodhane_rule.score_curve_growth_ok('[[1, 1.15]]')
    and not kodhane_rule.score_curve_growth_ok('[[0, 1.15], [300, 1.1], [300, 1.05]]') and not kodhane_rule.score_curve_growth_ok('[[0, 1.0]]')
    and not kodhane_rule.score_curve_growth_ok('[[0, 2.5]]') and not kodhane_rule.score_curve_growth_ok('[[0, 1.15], [10.5, 1.1]]')
    and not kodhane_rule.score_curve_growth_ok('{}') and not kodhane_rule.score_curve_growth_ok('[]')
  union all select 9, 'vectors: empty save true; v4.5 sim save at asama_1e21 (F-asap-tutkulu-30g #6, 1.15e21 after 12 h, v4.4b: false) true; unknown stage id false; 1e40 after 2 h false',
    public.kodhane_score_plausible('{"totalEarned": 0}'::jsonb, now())
    and public.kodhane_score_plausible(jsonb_build_object('saveVersion', 5, 'version', 5, 'totalEarned', 1149894005101156100000, 'runEarned', 0,
          'cycleEarned', 1149894005100534700000, 'shares', 5441797, 'prestigeCount', 22, 'cycleRounds', 19, 'ipoCount', 1, 'ipoSharesEarned', 1,
          'stageId', 'freelancer', 'stageBestId', 'asama_1e21', 'cycleStageId', 'asama_1e21', 'tree', jsonb_build_array('ekip_1'),
          'startedAt', floor(extract(epoch from now() - interval '12 hours') * 1000), 'lastSaved', floor(extract(epoch from now()) * 1000)), now())
    and not public.kodhane_score_plausible(jsonb_build_object('saveVersion', 5, 'totalEarned', 1e6, 'stageId', 'asama_9e99', 'startedAt', floor(extract(epoch from now() - interval '30 days') * 1000)), now())
    and not public.kodhane_score_plausible(jsonb_build_object('saveVersion', 5, 'totalEarned', 1e40, 'runEarned', 1e40, 'cycleEarned', 1e40,
          'startedAt', floor(extract(epoch from now() - interval '2 hours') * 1000), 'lastSaved', floor(extract(epoch from now()) * 1000)), now())
  union all select 10, 'B objects unchanged: leaderboard v7, version guard, stage id trigger function (md5 as after B)',
    md5(pg_get_functiondef('public.kodhane_leaderboard_v7(integer)'::regprocedure)) = 'f555378d3cf4d133f613a183d579215e'
    and md5(pg_get_functiondef('public.kodhane_save_version_guard()'::regprocedure)) = '2f53fdfdfa3983cd536cccfd9d7a2105'
    and md5(pg_get_functiondef('public.kodhane_save_v44_stage_id()'::regprocedure)) = 'd7572e2676d35d0182e545e8cf92846c'
  union all select 11, 'stage catalogue v4.5: asama_1e21 rank 10 at 1e21 (mars_ofisi 11), stage_rank e1c7af80 / stage_at f875dd82, CHECK knows asama_1e21 (validated, md5 2325f405)',
    public.kodhane_stage_rank('asama_1e21') = 10 and public.kodhane_stage_rank('mars_ofisi') = 11 and public.kodhane_stage_rank('yapay_zeka_lab') = 9
    and public.kodhane_stage_at('asama_1e21') = 1e21 and public.kodhane_stage_at('mars_ofisi') = 1e23
    and public.kodhane_stage_id_max('yapay_zeka_lab', 'asama_1e21', null) = 'asama_1e21'
    and md5(pg_get_functiondef('public.kodhane_stage_rank(text)'::regprocedure)) = 'e1c7af8061bc48883d2ea911213f990a'
    and md5(pg_get_functiondef('public.kodhane_stage_at(text)'::regprocedure)) = 'f875dd829a4e2a62a9d4b3457aa018a5'
    and (select md5(pg_get_constraintdef(oid)) = '2325f40530fa6b360ca0583641750b6b' and convalidated from pg_constraint
          where conrelid = 'public.kodhane_saves'::regclass and conname = 'kodhane_saves_best_stage_id_known')
  union all select 12, 'backfill complete: no save whose vetted stage is asama_1e21 has a lower best_stage_id',
    not exists (select 1 from public.kodhane_saves k where public.kodhane_stage_rank(k.best_stage_id) < 10
                                                     and public.kodhane_save_vetted_stage_id(k.data) = 'asama_1e21')
  union all select 13, 'stage_1e21_log: owner postgres, RLS on, no table privilege for anon / authenticated / service_role; both log triggers enabled; every asama_1e21 save logged',
    (select pg_get_userbyid(relowner) = 'postgres' and relrowsecurity from pg_class where oid = 'kodhane_rule.stage_1e21_log'::regclass)
    and not exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r(r)
                     where has_table_privilege(r.r, 'kodhane_rule.stage_1e21_log', 'select,insert,update,delete,truncate'))
    and (select count(*) = 2 from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgenabled = 'O'
          and tgname in ('kodhane_saves_zz_stage_1e21_log_ins', 'kodhane_saves_zz_stage_1e21_log_upd'))
    and not exists (select 1 from public.kodhane_saves k where k.best_stage_id = 'asama_1e21'
                     and not exists (select 1 from kodhane_rule.stage_1e21_log l where l.user_id = k.user_id))
  union all select 14, 'kodhane_score_plausible: proconfig exactly search_path="" + jit=off (SET jit = off, 2026-10-04; the rollback removes it)',
    (select p.proconfig = array['search_path=""', 'jit=off'] from pg_proc p where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure)
)
select l from (
  select n, concat_ws('|', 'CHECK', 'sr_' || n, coalesce(ok, false), name) as l from c
  union all select 99, concat_ws('|', 'SRVERIFY', case when bool_and(coalesce(ok, false)) and count(*) = 14 then 'PASS' else 'FAIL' end, count(*)) from c
) x order by n;
select concat_ws('|', 'INFO', 'saves', count(*), 'plausible', count(*) filter (where coalesce(public.kodhane_score_plausible(data), false))) from public.kodhane_saves;
rollback;
