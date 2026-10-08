-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (dry-run / install): after the migrations, same transaction. Both
-- leaderboards must be identical to _kd_v44b_lb_before (rank, nickname, score, stage, is_me, status), and
-- kodhane_leaderboard_v7 must equal the v6 Kodhane list; otherwise the whole transaction is aborted (nothing installed).
do $lbcheck$
declare n_diff bigint; n_v7 bigint;
begin
  select count(*) into n_diff from (
    (select 'kodhane'::text as g, * from public.kodhane_leaderboard(100, 'kodhane')
     union all select 'acik_ofis', * from public.kodhane_leaderboard(100, 'acik_ofis')
     except all select * from _kd_v44b_lb_before)
    union all
    (select * from _kd_v44b_lb_before
     except all (select 'kodhane'::text, * from public.kodhane_leaderboard(100, 'kodhane')
                 union all select 'acik_ofis', * from public.kodhane_leaderboard(100, 'acik_ofis')))) d;
  select count(*) into n_v7 from (
    (select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard_v7(100)
     except all select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard(100, 'kodhane'))
    union all
    (select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard(100, 'kodhane')
     except all select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard_v7(100))) d;
  if n_diff > 0 or n_v7 > 0 then
    raise exception 'STOP: leaderboard changed by the migrations (% row(s) differ; v7 vs v6: % row(s)); transaction aborted', n_diff, n_v7;
  end if;
end $lbcheck$;
select concat_ws('|', 'CHECK', 'leaderboard_same_before_after_and_v7_eq_v6', 't', (select count(*) from _kd_v44b_lb_before) || ' rows');
