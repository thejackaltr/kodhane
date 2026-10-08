-- Deletion log install preflight (READ ONLY): target, existing objects. STOP on a wrong target.
do $g$
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('public.kodhane_save_backups') is null or to_regclass('auth.users') is null then
    raise exception 'STOP: wrong target (public.kodhane_saves / kodhane_save_backups / auth.users missing in database %)', current_database();
  end if;
  if to_regclass('public.fenomen_saves') is not null then raise exception 'STOP: wrong target (public.fenomen_saves exists)'; end if;
end $g$;
select 'INFO|db|' || current_database() || '|' || current_user;
select 'INFO|kodhane_private|' || case when to_regnamespace('kodhane_private') is null then 'absent' else 'present' end
    || '|deletion_log|' || case when to_regclass('kodhane_private.deletion_log') is null then 'absent (fresh install)' else 'present (re-run: idempotent)' end;
select 'INFO|progress_log|' || (to_regclass('public.kodhane_progress_log') is not null) || '|package_b|'
    || (to_regprocedure('public.kodhane_stage_ids_version_guard()') is not null) || '|retention_audit_fn|'
    || (to_regprocedure('public.kodhane_cleanup_audit_log(integer)') is not null) || ' (none of these is required)';
select 'INFO|postgres_bypassrls|' || rolbypassrls from pg_roles where rolname = 'postgres';
select 'INFO|kodhane_saves|' || count(*) || '|auth_users|' || (select count(*) from auth.users) from public.kodhane_saves;
