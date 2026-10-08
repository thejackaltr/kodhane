-- =====================================================================================================
-- Kodhane v4.4 backend: deletion log (silme listesi). Design: plans/silme-listesi-kodhane-tasarim.md, after Fenomen v2.2
-- (feaec45). NOT part of package B / kodhane_v44b_install.sh install.sql: a separate install step with its own approval
-- (docs/kodhane-account-delete-runbook.md, "Silme listesi"). Needs Kodhane v2.2 only (not A, B or the progress log).
--
-- Why: a DB restore must not bring back accounts or Kodhane data deleted after the backup. Every deletion by
-- ops/kodhane_account_delete.sql writes (in the same transaction) one row here; ops/kodhane_deletion_log_export.sh copies
-- the list OUT of the DB; after a restore ops/kodhane_deletion_log_reapply.sh deletes the listed uids again.
--
-- kodhane_private.deletion_log (user_id uuid, scope text, deleted_at timestamptz, approval_ref text), PK (user_id, scope):
--   scope 'account'  mode=full: the auth user and both games' rows are gone; reapply = the full delete again.
--   scope 'kodhane'  mode=kodhane_only: only Kodhane rows (+ sessions); reapply deletes Kodhane rows only, and only if
--                    they are older than deleted_at (a player who played again after the deletion keeps the new save).
--   approval_ref: '(self|info|purge):<ref>', no @ (no e-mail), comma, double quote, backslash or control character.
--   No e-mail, no nickname. The first row of a uid + scope stays (writers use ON CONFLICT DO NOTHING).
--   Schema owner postgres, no USAGE for anon / authenticated / service_role; table owner postgres, RLS on + FORCE, no policy,
--   no privilege for anon / authenticated / service_role. Only postgres (owner, BYPASSRLS) and superusers reach it.
-- kodhane_private.cfg_deletion_log_retention() returns interval: 45 days = longest backup retention (Kodhane save backups
--   30 days; GM's daily DB backups ~14 days) + 15 days margin. The single place for the value.
-- kodhane_private.cleanup_deletion_log() returns integer: deletes rows older than the retention, returns the count.
--   EXECUTE: postgres only (owner). Daily, as the last step of the Dokploy retention command
--   (ops/kodhane_retention_dokploy_command*_with_deletion_log.txt) or ops/kodhane_retention_daily.sh step 5.
--
-- Run (no -1; the file has its own transaction), as supabase_admin or postgres:
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261003040000_v4_4_kodhane_deletion_log.sql
-- Check: supabase/ops/kodhane_deletion_log_install_verify.sql. Idempotent.
-- Rollback: supabase/rollback/20261003040000_v4_4_kodhane_deletion_log.rollback.sql (refuses while the list has rows).
-- =====================================================================================================
begin;

do $pre$
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('public.kodhane_save_backups') is null
     or to_regclass('auth.users') is null then
    raise exception 'kodhane deletion log: wrong target (public.kodhane_saves / kodhane_save_backups / auth.users missing in database %)', current_database();
  end if;
  if to_regclass('public.fenomen_saves') is not null then
    raise exception 'kodhane deletion log: wrong target (public.fenomen_saves exists: this is a Fenomen database)';
  end if;
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'postgres') then
    raise exception 'kodhane deletion log: role postgres missing';
  end if;
end $pre$;

create schema if not exists kodhane_private authorization postgres;
alter schema kodhane_private owner to postgres;
revoke all on schema kodhane_private from public, anon, authenticated, service_role;
comment on schema kodhane_private is 'Kodhane internal data, no API access (deletion log). Migration 20261003040000.';

create table if not exists kodhane_private.deletion_log (
  user_id      uuid        not null,
  scope        text        not null constraint deletion_log_scope_check check (scope in ('account', 'kodhane')),
  deleted_at   timestamptz not null default now(),
  approval_ref text        not null constraint deletion_log_approval_ref_check
                             check (approval_ref ~ '^(self|info|purge):[^@,"\\[:cntrl:]]{1,200}$'),
  constraint deletion_log_pkey primary key (user_id, scope)
);
create index if not exists deletion_log_deleted_at_idx on kodhane_private.deletion_log (deleted_at);
alter table kodhane_private.deletion_log owner to postgres;
alter table kodhane_private.deletion_log enable row level security;
alter table kodhane_private.deletion_log force row level security;
revoke all on table kodhane_private.deletion_log from public, anon, authenticated, service_role;
comment on table kodhane_private.deletion_log is
  'Kodhane deletion log: uid + scope (account | kodhane) + time + approval reference of every deletion; no e-mail. Kept 45 days (cfg_deletion_log_retention). Reapplied after a DB restore. Migration 20261003040000.';

create or replace function kodhane_private.cfg_deletion_log_retention()
returns interval language sql immutable set search_path = '' as $$ select interval '45 days' $$;
comment on function kodhane_private.cfg_deletion_log_retention() is
  '45 days = longest backup retention (Kodhane save backups 30 days, DB backups ~14 days) + 15 days margin.';

create or replace function kodhane_private.cleanup_deletion_log()
returns integer language plpgsql set search_path = '' as $$
declare n integer;
begin
  delete from kodhane_private.deletion_log d where d.deleted_at < pg_catalog.now() - kodhane_private.cfg_deletion_log_retention();
  get diagnostics n = row_count;
  return n;
end $$;
comment on function kodhane_private.cleanup_deletion_log() is
  'Deletes deletion log rows older than cfg_deletion_log_retention() (45 days); returns the count. Daily retention step.';

alter function kodhane_private.cfg_deletion_log_retention() owner to postgres;
alter function kodhane_private.cleanup_deletion_log() owner to postgres;
revoke all on function kodhane_private.cfg_deletion_log_retention() from public, anon, authenticated, service_role;
revoke all on function kodhane_private.cleanup_deletion_log() from public, anon, authenticated, service_role;

commit;
