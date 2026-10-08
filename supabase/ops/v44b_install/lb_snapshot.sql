-- PARTIAL of supabase/ops/kodhane_v44b_install.sh: leaderboard fingerprint (both games), md5 + row count only.
-- Columns as the clients see them (rank, nickname, score, stage, status; is_me is false for supabase_admin).
select concat_ws('|', 'LB', g, count(*), md5(coalesce(string_agg(concat_ws(':', rank, nickname, score, stage, status), E'\n' order by rank, nickname), '')))
  from (select 'kodhane' as g, * from public.kodhane_leaderboard(100, 'kodhane')
        union all select 'acik_ofis', * from public.kodhane_leaderboard(100, 'acik_ofis')) x
 group by g order by g;
