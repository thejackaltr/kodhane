-- PARTIAL of supabase/ops/kodhane_score_rule_install.sh (build -> rollback_preview.sql, READ ONLY): the rows the
-- rollback will write, with the same rule as the rollback file (logged value before; no log entry -> yapay_zeka_lab).
-- RBJIT: the function settings now; the rollback's v4.4b definition has search_path only (SET jit = off is removed).
select concat_ws('|', 'RBJIT', coalesce(array_to_string(p.proconfig, ','), '-'),
                 case when 'jit=off' = any(coalesce(p.proconfig, '{}')) then 'rollback removes jit=off from kodhane_score_plausible (v4.4b definition: search_path only)'
                      else 'no jit setting on kodhane_score_plausible' end)
  from pg_proc p where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure;
select to_regclass('kodhane_rule.stage_1e21_log') is not null as sr_has_log \gset
\if :sr_has_log
select concat_ws('|', 'RBCOUNT', count(*), 'backfill', count(*) filter (where l.source = 'backfill'), 'trigger', count(*) filter (where l.source = 'trigger'),
                 'nolog', count(*) filter (where l.source is null))
  from public.kodhane_saves k left join kodhane_rule.stage_1e21_log l on l.user_id = k.user_id where k.best_stage_id = 'asama_1e21';
select concat_ws('|', 'RBROW', k.user_id, k.best_stage_id, case when l.source is null then 'yapay_zeka_lab' else coalesce(l.old_best_stage_id, 'NULL') end,
                 coalesce(l.source, 'nolog'))
  from public.kodhane_saves k left join kodhane_rule.stage_1e21_log l on l.user_id = k.user_id where k.best_stage_id = 'asama_1e21' order by k.user_id;
\else
select concat_ws('|', 'RBCOUNT', count(*), 'backfill', 0, 'trigger', 0, 'nolog', count(*)) from public.kodhane_saves where best_stage_id = 'asama_1e21';
select concat_ws('|', 'RBROW', user_id, best_stage_id, 'yapay_zeka_lab', 'nolog') from public.kodhane_saves where best_stage_id = 'asama_1e21' order by user_id;
\endif
