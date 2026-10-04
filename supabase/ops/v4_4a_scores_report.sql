-- Kodhane v4.4 PACKAGE A: counted score of two named saves, for the report (READ ONLY, rolled back). Run right BEFORE
-- and right AFTER the migration (next to the leaderboard snapshots):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v4_4a_scores_report.sql > a-scores-before.txt   (then a-scores-after.txt)
-- Keys = left(md5(user_id), 16): fa7c574270bdf8c6 = compensated save (06:53 TSİ hand compensation, rewritten 16:13 TSİ),
-- a3a7039e7eb78104 = reference save (top row). Expected: same rule / vetted / best / rank before and after A. No nickname / e-mail.
-- SCORE | key | role | revision | rule now | kodhane_save_vetted_score (what a write would count) | best_score | totalEarned
--       | leaderboard v6 rank | score | stage | status   (leaderboard columns empty = not on the list)
\set ON_ERROR_STOP on
begin transaction read only;
show transaction_read_only;
\pset format unaligned
\pset tuples_only on
\pset fieldsep '|'
select 'TS', to_char(clock_timestamp() at time zone 'Europe/Istanbul', 'YYYY-MM-DD HH24:MI:SS') || ' TSİ';
select 'PLAUS', md5(p.prosrc), l.lanname from pg_proc p join pg_language l on l.oid = p.prolang
 where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure;
with k(key, role, ord) as (values ('fa7c574270bdf8c6', 'compensated', 1), ('a3a7039e7eb78104', 'reference', 2)),
lb as (select x.* from public.kodhane_leaderboard(100, 'kodhane') x),
lbk as (select left(md5(p.user_id::text), 16) as key, lb.* from lb join public.kodhane_profiles p on p.nickname = lb.nickname)
select 'SCORE', k.key, k.role, s.revision, public.kodhane_score_plausible(s.data), public.kodhane_save_vetted_score(s.data),
       s.best_score, public.kodhane_save_score(s.data), l.rank, l.score, l.stage, l.status,
       (select count(*) from public.kodhane_saves s2 where left(md5(s2.user_id::text), 16) = k.key) as n
  from k left join public.kodhane_saves s on left(md5(s.user_id::text), 16) = k.key
  left join lbk l on l.key = k.key order by k.ord;
rollback;
