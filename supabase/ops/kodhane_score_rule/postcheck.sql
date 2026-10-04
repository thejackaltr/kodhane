-- PARTIAL of supabase/ops/kodhane_score_rule_install.sh (dryrun / install, AFTER the migration, same transaction).
-- The v4.5 rule is more generous than v4.4b for every save (higher income cap, one more stage): no save that is
-- plausible now may become implausible. Otherwise exception -> nothing committed.
select concat_ws('|', 'INFO', 'saves', count(*), 'plausible_before', count(*) filter (where o.ok),
                 'plausible_after', count(*) filter (where coalesce(public.kodhane_score_plausible(k.data), false)),
                 'became_true', count(*) filter (where not o.ok and coalesce(public.kodhane_score_plausible(k.data), false)))
  from _sr_old o join public.kodhane_saves k using (user_id);
do $sr_chk$
declare n bigint;
begin
  select count(*) into n from _sr_old o join public.kodhane_saves k using (user_id)
   where o.ok and not coalesce(public.kodhane_score_plausible(k.data), false);
  if n > 0 then
    raise exception 'v4.5 score rule: % save(s) plausible under v4.4b would become implausible; rolled back', n;
  end if;
end $sr_chk$;
select concat_ws('|', 'CHECK', 'no_save_became_implausible', true);
select concat_ws('|', 'LB', 'before', count(*), md5(coalesce(string_agg(concat_ws(':', rank, nickname, score, stage, stage_id, status), E'\n' order by rank, nickname), '')))
  from _sr_lb0;
select concat_ws('|', 'LB', 'after', count(*), md5(coalesce(string_agg(concat_ws(':', rank, nickname, score, stage, stage_id, status), E'\n' order by rank, nickname), '')))
  from public.kodhane_leaderboard_v7(1000);
select concat_ws('|', 'CHECK', 'leaderboard_nobody_dropped',
                 not exists (select nickname, score from _sr_lb0 except select nickname, score from public.kodhane_leaderboard_v7(1000)));
