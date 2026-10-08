-- Rollback of supabase/migrations/20261001210000_v4_4_kodhane_audit_log_retention.sql: drops
-- public.kodhane_cleanup_audit_log(integer). Stop the daily job first (Dokploy scheduled task), else it fails every night.
-- Deleted audit rows do not come back (only from a DB backup). Idempotent.
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/rollback/20261001210000_v4_4_kodhane_audit_log_retention.rollback.sql
begin;
drop function if exists public.kodhane_cleanup_audit_log(integer);
notify pgrst, 'reload schema';
commit;
