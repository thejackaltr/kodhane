-- v2.2 leaderboard snapshot (READ ONLY): what anon sees in both lists (top 100), for a before/after diff.
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v2_2_leaderboard_snapshot.sql > lb-<phase>.txt
-- Output: game|rank|nickname|score|stage|status. Expected diff before -> right after the two migrations: none, except
-- Kodhane rows whose saved stage is not believable for their totalEarned (v6 shows best_stage, which is vetted: such a
-- stage is shown lower). See v2_2_verify.sql V16 for the count.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset footer off
begin read only;
select 'kodhane', rank, nickname, score, stage, status from public.kodhane_leaderboard(100, 'kodhane')
union all
select 'acik_ofis', rank, nickname, score, stage, status from public.kodhane_leaderboard(100, 'acik_ofis')
order by 1, 2, 3;
commit;
