-- Rollback of supabase/migrations/20261003020000_v4_4_kodhane_progress_log.sql: drops the trigger
-- kodhane_saves_z_progress_log, public.kodhane_progress_log_write(), public.kodhane_cleanup_progress_log(integer, integer)
-- and the table public.kodhane_progress_log WITH ITS ROWS. Save writes are not affected (the trigger only logs).
-- Refuses while the table has rows, unless the loss is confirmed for this session:
--   PGOPTIONS='-c kodhane.progress_log_allow_loss=on' \
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/rollback/20261003020000_v4_4_kodhane_progress_log.rollback.sql
-- Without the confirmation only the trigger can be switched off: ALTER TABLE public.kodhane_saves DISABLE TRIGGER kodhane_saves_z_progress_log;
-- If a daily cleanup step was added to the Dokploy command, remove it first. Idempotent.
begin;
do $guard$
declare n bigint;
begin
  if to_regclass('public.kodhane_progress_log') is not null then
    execute 'select count(*) from public.kodhane_progress_log' into n;
    if n > 0 and coalesce(current_setting('kodhane.progress_log_allow_loss', true), '') <> 'on' then
      raise exception 'kodhane progress log rollback: the table has % row(s) that would be lost; set kodhane.progress_log_allow_loss=on to confirm (nothing dropped)', n;
    end if;
  end if;
end $guard$;
drop trigger if exists kodhane_saves_z_progress_log on public.kodhane_saves;
drop function if exists public.kodhane_progress_log_write();
drop function if exists public.kodhane_cleanup_progress_log(integer, integer);
drop table if exists public.kodhane_progress_log;
notify pgrst, 'reload schema';
commit;
