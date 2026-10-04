-- Rollback of supabase/migrations/20261003040000_v4_4_kodhane_deletion_log.sql: drops kodhane_private.cleanup_deletion_log(),
-- kodhane_private.cfg_deletion_log_retention(), the table kodhane_private.deletion_log WITH ITS ROWS and the schema
-- kodhane_private (only if it is then empty). Account deletion keeps working without the list (no row written).
-- Export the list first (ops/kodhane_deletion_log_export.sh). Refuses while the table has rows, unless the loss is
-- confirmed for this session:
--   PGOPTIONS='-c kodhane.deletion_log_allow_loss=on' \
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/rollback/20261003040000_v4_4_kodhane_deletion_log.rollback.sql
-- If the cleanup step was added to the Dokploy retention command (..._with_deletion_log.txt), switch back to the command
-- without it FIRST. Idempotent.
begin;
do $guard$
declare n bigint;
begin
  if to_regclass('kodhane_private.deletion_log') is not null then
    execute 'select count(*) from kodhane_private.deletion_log' into n;
    if n > 0 and coalesce(current_setting('kodhane.deletion_log_allow_loss', true), '') <> 'on' then
      raise exception 'kodhane deletion log rollback: the list has % row(s) that would be lost; export it, then set kodhane.deletion_log_allow_loss=on to confirm (nothing dropped)', n;
    end if;
  end if;
end $guard$;
drop function if exists kodhane_private.cleanup_deletion_log();
drop function if exists kodhane_private.cfg_deletion_log_retention();
drop table if exists kodhane_private.deletion_log;
do $schema$
begin
  if to_regnamespace('kodhane_private') is not null
     and not exists (select 1 from pg_catalog.pg_class where relnamespace = to_regnamespace('kodhane_private'))
     and not exists (select 1 from pg_catalog.pg_proc where pronamespace = to_regnamespace('kodhane_private'))
     and not exists (select 1 from pg_catalog.pg_type where typnamespace = to_regnamespace('kodhane_private')) then
    drop schema kodhane_private;
  end if;
end $schema$;
commit;
