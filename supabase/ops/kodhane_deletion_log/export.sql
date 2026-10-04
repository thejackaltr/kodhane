-- READ ONLY export of kodhane_private.deletion_log (used by ops/kodhane_deletion_log_export.sh; the script adds the psql
-- prefix and the begin read only / commit lines). Output lines: DLX|... (status), DL|uid|scope|deleted_at UTC|ref, DLN|count.
do $g$
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('auth.users') is null then
    raise exception 'DLX|STOP|wrong target: public.kodhane_saves / auth.users missing in database %', current_database();
  end if;
  if to_regclass('public.fenomen_saves') is not null then
    raise exception 'DLX|STOP|wrong target: public.fenomen_saves exists (Fenomen database)';
  end if;
  if to_regclass('kodhane_private.deletion_log') is null then
    raise exception 'DLX|STOP|kodhane_private.deletion_log does not exist (migration 20261003040000 not installed)';
  end if;
end $g$;
select 'DLX|db|' || current_database() || '|retention_days|' || extract(day from kodhane_private.cfg_deletion_log_retention())::int;
select 'DL|' || d.user_id || '|' || d.scope || '|' || to_char(d.deleted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' || d.approval_ref
  from kodhane_private.deletion_log d order by d.deleted_at, d.user_id, d.scope;
select 'DLN|' || count(*) from kodhane_private.deletion_log;
