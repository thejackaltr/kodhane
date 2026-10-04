-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (rollback.sql): after the progress-log rollback and the B rollback, same
-- transaction. The database must be back at package A exactly as installed on 2026-10-01 (md5 969e1dc2...), else the
-- whole rollback is aborted (nothing changed).
do $rbcheck$
declare problems text[] := '{}'; a_md5 text; trg text[];
begin
  a_md5 := md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure));
  if a_md5 <> '969e1dc203fa1877a57e2cf3fcc2727c' then
    problems := problems || format('kodhane_score_plausible md5 %s, expected A 969e1dc203fa1877a57e2cf3fcc2727c', a_md5);
  end if;
  if to_regprocedure('public.kodhane_leaderboard_v7(integer)') is not null or to_regprocedure('public.kodhane_save_version_guard()') is not null
     or to_regprocedure('public.kodhane_stage_rank(text)') is not null
     or exists (select 1 from pg_attribute where attrelid = 'public.kodhane_saves'::regclass and attname = 'best_stage_id' and not attisdropped) then
    problems := problems || 'package B objects still present'::text;
  end if;
  if to_regclass('public.kodhane_progress_log') is not null or to_regprocedure('public.kodhane_progress_log_write()') is not null
     or to_regprocedure('public.kodhane_cleanup_progress_log(integer,integer)') is not null then
    problems := problems || 'progress log objects still present'::text;
  end if;
  select array_agg(tgname::text || ':' || tgenabled::text order by tgname) into trg
    from pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and not tgisinternal;
  if trg is distinct from array['kodhane_saves_before_delete:O', 'kodhane_saves_before_write:O'] then
    problems := problems || format('kodhane_saves triggers %s', trg);
  end if;
  if cardinality(problems) > 0 then
    raise exception 'STOP: rollback check failed, transaction aborted: %', array_to_string(problems, '; ');
  end if;
end $rbcheck$;
select concat_ws('|', 'CHECK', 'rollback_back_at_A', 't', md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure)));
