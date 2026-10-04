-- Kodhane v4.4 PACKAGE A: leaderboard + rule snapshot (READ ONLY, rolled back). Run right BEFORE and right AFTER the migration,
-- then compare with supabase/ops/v4_4a_leaderboard_compare.py. Expected: no save's rule result changes (newly_accepted 0,
-- newly_flagged 0); score / rank moves only on rows whose save was written by the player between the two reads.
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v4_4a_leaderboard_snapshot.sql > lb-before.txt   (then lb-after.txt)
-- Prints no nickname / e-mail / save content: row key = left(md5(user_id), 16); per save: current rule result (boolean),
-- updated_at (epoch) and revision; per leaderboard row: rank, score, stage, status. Leaderboard rows are keyed by joining the nickname back
-- to the game's profiles table (the nickname itself is not printed).
\set ON_ERROR_STOP on
begin transaction read only;
show transaction_read_only;
\pset format unaligned
\pset tuples_only on
\pset fieldsep '|'
select 'TS0', extract(epoch from clock_timestamp())::numeric(20,6);
select 'SIG', md5(pg_get_functiondef('public.kodhane_leaderboard(integer,text)'::regprocedure));
select 'PLAUS', md5(p.prosrc), l.lanname from pg_proc p join pg_language l on l.oid = p.prolang
 where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure;
-- live v6 signature: kodhane_leaderboard(p_limit integer default 50, p_game text default 'kodhane'), limit capped at 100
with lb as (select row_number() over () as i, x.* from public.kodhane_leaderboard(100, 'kodhane') x)
select 'LB', 'kodhane', coalesce(left(md5(p.user_id::text), 16), 'nokey' || lb.i), coalesce(p.user_id::text like '5e172611%', false),
       lb.rank, lb.score, lb.stage, lb.status, coalesce(extract(epoch from s.updated_at)::numeric(20,6)::text, ''),
       (select count(*) from public.kodhane_profiles p2 where p2.nickname = lb.nickname)
  from lb left join public.kodhane_profiles p on p.nickname = lb.nickname
  left join public.kodhane_saves s on s.user_id = p.user_id order by lb.i;
with lb as (select row_number() over () as i, x.* from public.kodhane_leaderboard(100, 'acik_ofis') x)
select 'LB', 'acik_ofis', coalesce(left(md5(p.user_id::text), 16), 'nokey' || lb.i), false,
       lb.rank, lb.score, lb.stage, lb.status, coalesce(extract(epoch from s.updated_at)::numeric(20,6)::text, ''),
       (select count(*) from public.acik_ofis_profiles p2 where p2.nickname = lb.nickname)
  from lb left join public.acik_ofis_profiles p on p.nickname = lb.nickname
  left join public.acik_ofis_saves s on s.user_id = p.user_id order by lb.i;
-- every save: rule result of the live plausibility function now + updated_at + revision (tells a player write from a rule change)
select 'RULE', 'kodhane', left(md5(user_id::text), 16), coalesce(public.kodhane_score_plausible(data)::text, 'null'),
       extract(epoch from updated_at)::numeric(20,6), revision from public.kodhane_saves order by 3;
select 'RULE', 'acik_ofis', left(md5(user_id::text), 16), coalesce(public.acik_ofis_score_plausible(data)::text, 'null'),
       extract(epoch from updated_at)::numeric(20,6), revision from public.acik_ofis_saves order by 3;
select 'TS1', extract(epoch from clock_timestamp())::numeric(20,6);
rollback;
