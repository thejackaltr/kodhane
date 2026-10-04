-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (dry-run / install): leaderboard of both games BEFORE the migrations,
-- in the same transaction (same now(), so the time-based plausibility rule gives the same answer before and after).
create temp table _kd_v44b_lb_before on commit drop as
  select 'kodhane'::text as g, * from public.kodhane_leaderboard(100, 'kodhane')
  union all select 'acik_ofis', * from public.kodhane_leaderboard(100, 'acik_ofis');
-- kodhane_score_plausible (A) of every stored save, to compare with v4.4b after the migrations
create temp table _kd_v44b_plaus_before on commit drop as
  select user_id, public.kodhane_score_plausible(data) as ok from public.kodhane_saves;
