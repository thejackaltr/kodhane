-- PARTIAL of supabase/ops/kodhane_score_rule_install.sh (dryrun / install, BEFORE the migration, same transaction):
-- every save's judgement under the current rule + the leaderboard, for the check after the migration.
create temp table _sr_old on commit drop as
  select k.user_id, coalesce(public.kodhane_score_plausible(k.data), false) as ok from public.kodhane_saves k;
create temp table _sr_lb0 on commit drop as select * from public.kodhane_leaderboard_v7(1000);
