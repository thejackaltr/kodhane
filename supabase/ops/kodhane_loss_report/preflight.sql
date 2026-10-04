-- Kayıp bildir (migration 20261003060000) install preflight (READ ONLY): target, prerequisites, existing objects.
do $g$
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('public.kodhane_save_backups') is null or to_regclass('auth.users') is null then
    raise exception 'STOP: wrong target (public.kodhane_saves / kodhane_save_backups / auth.users missing in database %)', current_database();
  end if;
  if to_regclass('public.fenomen_saves') is not null then raise exception 'STOP: wrong target (public.fenomen_saves exists)'; end if;
  if not exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgname = 'kodhane_saves_a_version_guard' and tgenabled = 'O')
     or to_regprocedure('public.kodhane_leaderboard_v7(integer)') is null then
    raise exception 'STOP: package B (20260929204000) is not installed / its version guard is not enabled: install B + progress log first';
  end if;
  if to_regclass('public.kodhane_progress_log') is null
     or not exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgname = 'kodhane_saves_z_progress_log' and tgenabled = 'O') then
    raise exception 'STOP: the progress log (20261003020000) is not installed / its trigger is not enabled';
  end if;
end $g$;
select 'INFO|db|' || current_database() || '|' || current_user;
select 'INFO|kodhane_loss|' || case when to_regnamespace('kodhane_loss') is null then 'absent (fresh install)' else 'present (re-run: idempotent)' end
    || '|loss_report_rows|' || case when to_regclass('kodhane_loss.loss_report') is null then '0' else '(table present)' end;
select 'INFO|deletion_log|' || (to_regclass('kodhane_private.deletion_log') is not null) || ' (not required)|retention_audit_fn|'
    || (to_regprocedure('public.kodhane_cleanup_audit_log(integer)') is not null);
select 'INFO|postgres_bypassrls|' || rolbypassrls || '|rolsuper|' || rolsuper from pg_roles where rolname = 'postgres';
select 'INFO|kodhane_saves|' || count(*) from public.kodhane_saves;
