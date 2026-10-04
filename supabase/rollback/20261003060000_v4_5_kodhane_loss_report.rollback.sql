-- Rollback of supabase/migrations/20261003060000_v4_5_kodhane_loss_report.sql: drops the player RPCs
-- public.kodhane_loss_report_create / _status, every kodhane_loss.loss_report* function, cfg_loss_report(),
-- cleanup_loss_reports(), the table kodhane_loss.loss_report WITH ITS ROWS and the schema kodhane_loss. B, the progress log (incl. its telafi rows), the deletion log and
-- every save stay as they are; an applied restore is NOT undone (its 'manual' backup stays in kodhane_save_backups).
-- Account deletion keeps working (the delete skips the loss report step when the table is gone).
-- Refuses while the table has rows, unless the loss is confirmed for this session (list them first: runbook "Geri alma"):
--   PGOPTIONS='-c kodhane.loss_report_allow_loss=on' \
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/rollback/20261003060000_v4_5_kodhane_loss_report.rollback.sql
-- Idempotent.
begin;
do $guard$
declare n bigint;
begin
  if to_regclass('kodhane_loss.loss_report') is not null then
    execute 'select count(*) from kodhane_loss.loss_report' into n;
    if n > 0 and coalesce(current_setting('kodhane.loss_report_allow_loss', true), '') <> 'on' then
      raise exception 'kodhane loss report rollback: % report(s) would be lost; list them, then set kodhane.loss_report_allow_loss=on to confirm (nothing dropped)', n;
    end if;
  end if;
end $guard$;
drop function if exists public.kodhane_loss_report_create(text[], timestamptz, text, text);
drop function if exists public.kodhane_loss_report_status(integer);
drop function if exists kodhane_loss.loss_report_apply(bigint, text);
drop function if exists kodhane_loss.loss_report_reject(bigint, text, text);
drop function if exists kodhane_loss.loss_report_approve(bigint, text, timestamptz, jsonb, text, boolean);
drop function if exists kodhane_loss.loss_report_proposal(bigint, timestamptz);
drop function if exists kodhane_loss.loss_report_timeline(bigint, integer);
drop function if exists kodhane_loss.loss_report_queue(text);
drop function if exists kodhane_loss.loss_report_merge(jsonb, jsonb);
drop function if exists kodhane_loss.loss_report_check_values(jsonb);
drop function if exists kodhane_loss.loss_report_state_at(uuid, timestamptz, jsonb);
drop function if exists kodhane_loss.loss_report_fields(jsonb);
drop function if exists kodhane_loss.loss_report_check_ref(text);
drop function if exists kodhane_loss.loss_report_assert_ops();
drop function if exists kodhane_loss.cleanup_loss_reports();
drop function if exists kodhane_loss.cfg_loss_report();
drop table if exists kodhane_loss.loss_report;
drop schema if exists kodhane_loss;   -- no CASCADE: anything unexpected left in it stops the rollback
notify pgrst, 'reload schema';
commit;
