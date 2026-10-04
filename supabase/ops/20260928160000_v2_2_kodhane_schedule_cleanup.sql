-- =====================================================================================================
-- OPTIONAL ops step for supabase/migrations/20260928160000_v2_2_kodhane_save_safety.sql (DRAFT, NOT APPLIED ANYWHERE REAL)
-- Schedules public.kodhane_cleanup_save_backups() daily at 03:17 TSİ (= '17 0 * * *' UTC) as pg_cron job
-- 'kodhane_save_backups_cleanup'. One ops file per game (like the migrations): usable in the shared DB and in the game's own DB.
--   * Never creates/enables the pg_cron extension. If pg_cron is not enabled in this database: NOTICE and exit (no error).
--     Check first:  select * from pg_available_extensions where name = 'pg_cron';
--     Enabling it is a separate, explicit admin decision (Supabase Studio > Database > Extensions), not part of v2.2.
--   * Idempotent: an identical job is left alone, a drifted one (schedule/command/inactive) is repaired in place
--     (cron.schedule upserts by job name); running it twice leaves exactly one job. Touches no other job.
--   * Requires the migration (public.kodhane_cleanup_save_backups()) first.
-- Undo:   select cron.unschedule('kodhane_save_backups_cleanup');   (the game's v2.2 rollback also does this)
-- Run:    psql "$DB_URL" -1 -v ON_ERROR_STOP=1 -f supabase/ops/20260928160000_v2_2_kodhane_schedule_cleanup.sql
-- =====================================================================================================
begin;
set local role postgres;

do $ops$
declare
  c_name constant text := 'kodhane_save_backups_cleanup';
  c_sched constant text := '17 0 * * *';                         -- 03:17 Europe/Istanbul (UTC+3, no DST)
  c_cmd constant text := 'select public.kodhane_cleanup_save_backups()';
  j record;
begin
  if to_regprocedure('public.kodhane_cleanup_save_backups()') is null then
    raise exception 'public.kodhane_cleanup_save_backups() not found: apply migration 20260928160000_v2_2_kodhane_save_safety.sql first';
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron is not enabled in database %: nothing scheduled (this script never enables it). Backups are still trimmed per player on reset/restore; run select public.kodhane_cleanup_save_backups(); manually or from an external daily job.', current_database();
    return;
  end if;
  select jobid, schedule, command, active into j from cron.job where jobname = c_name order by jobid limit 1;
  if found and j.schedule = c_sched and j.command = c_cmd and j.active then
    raise notice 'pg_cron: job % (id %) already scheduled (% UTC), unchanged', c_name, j.jobid, c_sched;
    return;
  end if;
  perform cron.schedule(c_name, c_sched, c_cmd);               -- insert or update by name (same user)
  select jobid, active into j from cron.job where jobname = c_name order by jobid limit 1;
  if not j.active then perform cron.alter_job(j.jobid, active := true); end if;
  raise notice 'pg_cron: job % (id %) scheduled: % UTC -> %', c_name, j.jobid, c_sched, c_cmd;
end $ops$;

commit;
