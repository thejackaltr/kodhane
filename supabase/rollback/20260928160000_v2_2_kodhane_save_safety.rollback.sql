-- =====================================================================================================
-- ROLLBACK of supabase/migrations/20260928160000_v2_2_kodhane_save_safety.sql (DRAFT, NOT APPLIED ANYWHERE REAL)
-- Touches ONLY kodhane_* objects (the Açık Ofis v2.2 file and its objects are left alone, whether applied or not).
-- Restores: kodhane_saves without best_score/best_stage/revision/strict_revision, table-level SELECT/INSERT/UPDATE/DELETE
-- for authenticated + kodhane_saves_delete_own (as kodhane-cloud/schema.sql), and kodhane_leaderboard exactly as it was
-- before the migration (definition recorded in kodhane_game_config 'v22_pre.kodhane_leaderboard' on the first run:
-- v5 = kodhane-cloud/leaderboard.v5.sql, or the Açık Ofis v2.2 shim, or none -> dropped).
-- Roll back in the reverse order of application. If Kodhane is rolled back while Açık Ofis v2.2 stays, re-run the Açık
-- Ofis migration afterwards (idempotent): it re-installs its kodhane_leaderboard shim on top of the restored v5.
--
-- DATA LOSS WARNING: drops public.kodhane_save_backups (players' reset/restore snapshots), public.kodhane_game_config and
-- the best_score/best_stage columns. Players who already reset then show their CURRENT totalEarned (possibly 0) again.
-- Refuses to run while kodhane_save_backups has rows unless you first run
--     set v22.kodhane_allow_backup_loss = 'on';
-- Keep a copy first if needed (admin only):
--     create table public.kodhane_save_backups_archive_v22 as select * from public.kodhane_save_backups;
--     revoke all on public.kodhane_save_backups_archive_v22 from public, anon, authenticated;
-- The pg_cron job 'kodhane_save_backups_cleanup' (only created by the optional ops file) is unscheduled if present;
-- the pg_cron extension itself is never touched. Idempotent. Game client: revert the Kodhane v2.2 client first.
-- =====================================================================================================
begin;
set local role postgres;

do $guard$
declare n bigint := 0;
begin
  if to_regclass('public.kodhane_save_backups') is not null then
    execute 'select count(*) from public.kodhane_save_backups' into n;
  end if;
  if n > 0 and coalesce(current_setting('v22.kodhane_allow_backup_loss', true), '') <> 'on' then
    raise exception 'kodhane_save_backups has % row(s); set v22.kodhane_allow_backup_loss = ''on'' to drop them (see header)', n;
  end if;
end $guard$;

do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'kodhane_save_backups_cleanup') then
      perform cron.unschedule('kodhane_save_backups_cleanup');
    end if;
  end if;
end $cron$;

-- kodhane_leaderboard: back to the exact pre-migration definition recorded on the first migration run (v5 in today's
-- shared DB, the Açık Ofis v2.2 shim if that file was applied first, or none -> dropped). No marker = already rolled back.
do $lb$
declare pre jsonb;
begin
  if to_regclass('public.kodhane_game_config') is null then return; end if;
  execute 'select value from public.kodhane_game_config where key = $1' into pre using 'v22_pre.kodhane_leaderboard';
  if pre is null then
    raise exception 'kodhane_game_config has no v22_pre.kodhane_leaderboard marker: refusing to guess the previous leaderboard';
  end if;
  if not (pre ->> 'exists')::boolean then
    drop function if exists public.kodhane_leaderboard(int, text);
    return;
  end if;
  -- v5 reads public.acik_ofis_saves statically: body checks off so this also works without that table
  perform set_config('check_function_bodies', 'off', true);
  execute pre ->> 'def';
  execute format('comment on function public.kodhane_leaderboard(int, text) is %L', pre ->> 'comment');
  revoke all on function public.kodhane_leaderboard(int, text) from public;
  grant execute on function public.kodhane_leaderboard(int, text) to anon, authenticated, service_role;
  perform set_config('check_function_bodies', 'on', true);
end $lb$;

drop trigger if exists kodhane_saves_before_write on public.kodhane_saves;
drop trigger if exists kodhane_saves_before_delete on public.kodhane_saves;

drop function if exists public.kodhane_reset_save();
drop function if exists public.kodhane_restore_save(uuid);
drop function if exists public.kodhane_list_save_backups();
drop function if exists public.kodhane_cleanup_save_backups();
drop function if exists public.kodhane_save_backups_trim(uuid);
drop function if exists public.kodhane_save_before_write();
drop function if exists public.kodhane_save_before_delete();
drop table if exists public.kodhane_save_backups;      -- also drops its policy + indexes
drop function if exists public.kodhane_save_reset_payload(jsonb, numeric);
drop function if exists public.kodhane_save_version_of(jsonb);
drop function if exists public.kodhane_save_vetted_stage(jsonb);
drop function if exists public.kodhane_save_stage_checked(jsonb);
drop function if exists public.kodhane_save_stage(jsonb);
drop function if exists public.kodhane_save_vetted_score(jsonb);
drop function if exists public.kodhane_save_score(jsonb);
drop function if exists public.kodhane_save_backup_retention();
drop function if exists public.kodhane_config_int(text, int);
drop function if exists public.kodhane_config_text(text, text);
drop table if exists public.kodhane_game_config;

alter table public.kodhane_saves drop column if exists best_score, drop column if exists best_stage,
  drop column if exists revision, drop column if exists strict_revision;

-- grants + policy exactly as in kodhane-cloud/schema.sql
revoke all on table public.kodhane_saves from public, anon, authenticated;
grant select, insert, update, delete on table public.kodhane_saves to authenticated;
drop policy if exists "kodhane_saves_delete_own" on public.kodhane_saves;
create policy "kodhane_saves_delete_own" on public.kodhane_saves
  for delete to authenticated using ((select auth.uid()) = user_id);

commit;
notify pgrst, 'reload schema';
