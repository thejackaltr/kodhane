-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (dry-run / install): first statement of the transaction. Package A must
-- be exactly the definition installed on 2026-10-01 20:39 TSİ, and B / the progress log must not be there yet.
do $assert_a$
begin
  if md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure)) <> '969e1dc203fa1877a57e2cf3fcc2727c' then
    raise exception 'STOP: kodhane_score_plausible is not package A (md5 969e1dc2...); nothing installed';
  end if;
  if to_regprocedure('public.kodhane_leaderboard_v7(integer)') is not null or to_regclass('public.kodhane_progress_log') is not null then
    raise exception 'STOP: B or the progress log is already installed; nothing changed';
  end if;
end $assert_a$;
