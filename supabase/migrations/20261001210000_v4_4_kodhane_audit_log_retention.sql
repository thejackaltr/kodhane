-- =====================================================================================================
-- Kodhane v4.4 backend (todo 26): auth.audit_log_entries retention, 12 months.
-- SHARED DATABASE: GoTrue keeps ONE audit table for the whole auth instance, so this retention covers every user of
-- that instance: Kodhane AND Açık Ofis players (and anyone else on the same auth). See docs/kodhane-retention-runbook.md.
--
-- Creates public.kodhane_cleanup_audit_log(p_batch_size integer default 5000) returns integer:
--   * deletes at most p_batch_size rows with created_at < now() - interval '12 months' (oldest first) and returns the
--     number of deleted rows. Rows with created_at null are never deleted.
--   * p_batch_size must be 1..50000; anything else (null, 0, negative, > 50000) is an error (22023) and deletes nothing.
--   * one call = one batch = one short transaction. The daily job (supabase/ops/kodhane_retention_daily.sh) calls it
--     until it returns less than the batch size.
--   * security definer (owner postgres; service_role has no DELETE on auth tables), search_path = ''.
--   * EXECUTE: postgres (owner) and service_role only; revoked from PUBLIC, anon, authenticated.
-- Save backups (30 days, delete copies included) are NOT here: the existing v2.2 functions
-- public.kodhane_cleanup_save_backups() and public.acik_ofis_cleanup_save_backups() are used unchanged.
--
-- Refuses (error, nothing created) when: not the Kodhane database, auth.audit_log_entries is missing, or role postgres
-- has no DELETE / SELECT on auth.audit_log_entries (the function would fail at the first run), or the table has RLS on
-- and postgres cannot bypass it.
-- Run (no -1; the file has its own transaction):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261001210000_v4_4_kodhane_audit_log_retention.sql
-- Idempotent. Rollback: supabase/rollback/20261001210000_v4_4_kodhane_audit_log_retention.rollback.sql
-- =====================================================================================================
-- Run as supabase_admin (as the live ops do) or postgres. The function is created and then owned by postgres; no
-- "set role postgres", because postgres may lack CREATE on schema public where it is not the database owner.
begin;

do $pre$
begin
  if to_regclass('public.kodhane_saves') is null or to_regprocedure('public.kodhane_cleanup_save_backups()') is null then
    raise exception 'kodhane audit retention: wrong target (public.kodhane_saves / kodhane_cleanup_save_backups() missing in database %)', current_database();
  end if;
  if to_regclass('auth.audit_log_entries') is null then
    raise exception 'kodhane audit retention: auth.audit_log_entries is missing: not a Supabase database';
  end if;
  if not has_table_privilege('postgres', 'auth.audit_log_entries', 'DELETE') then
    raise exception 'kodhane audit retention: role postgres cannot DELETE auth.audit_log_entries: the cleanup would fail; nothing created';
  end if;
  if not has_table_privilege('postgres', 'auth.audit_log_entries', 'SELECT') then
    raise exception 'kodhane audit retention: role postgres cannot SELECT auth.audit_log_entries: the cleanup would fail; nothing created';
  end if;
  if (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = 'auth.audit_log_entries'::regclass)
     and not (select r.rolbypassrls from pg_catalog.pg_roles r where r.rolname = 'postgres') then
    raise exception 'kodhane audit retention: auth.audit_log_entries has RLS and postgres has no BYPASSRLS; nothing created';
  end if;
end $pre$;

create or replace function public.kodhane_cleanup_audit_log(p_batch_size integer default 5000)
returns integer language plpgsql volatile security definer set search_path = ''
as $$
declare n integer;
begin
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 50000 then
    raise exception 'kodhane_cleanup_audit_log: p_batch_size must be between 1 and 50000 (got %); nothing deleted', coalesce(p_batch_size::text, 'null')
      using errcode = '22023';
  end if;
  delete from auth.audit_log_entries a
   where a.id in (select x.id from auth.audit_log_entries x
                   where x.created_at < now() - interval '12 months'
                   order by x.created_at, x.id
                   limit p_batch_size);
  get diagnostics n = row_count;
  return n;
end $$;

alter function public.kodhane_cleanup_audit_log(integer) owner to postgres;

comment on function public.kodhane_cleanup_audit_log(integer) is
  'Kodhane v4.4 (todo 26): deletes at most p_batch_size (1..50000) auth.audit_log_entries rows older than 12 months, oldest first; returns the count. Shared auth: covers Kodhane and Açık Ofis users.';

revoke all on function public.kodhane_cleanup_audit_log(integer) from public, anon, authenticated;
grant execute on function public.kodhane_cleanup_audit_log(integer) to service_role;

notify pgrst, 'reload schema';
commit;
