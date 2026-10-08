-- PARTIAL of supabase/ops/kodhane_v44b_install.sh (restore): LAST RESORT, full in-place restore of a backup
-- (docs/kodhane-v44b-install-runbook.md, "Geri dönüş yolu 2"). Prepended to the output of
--   pg_restore --clean --if-exists -f - <dump>
-- and run with psql -1 (one transaction: an error restores nothing).
-- Why this prelude: Supabase sets ALTER DEFAULT PRIVILEGES (public schema: functions / tables / sequences to anon,
-- authenticated, service_role). pg_dump writes every object's grants relative to the built-in default, so objects re-created
-- by the restore would ALSO get those default grants (rehearsal: e.g. acik_ofis_cleanup_save_backups() executable by anon).
-- The prelude revokes every default privilege granted to a role other than its owner; the dump's own ALTER DEFAULT
-- PRIVILEGES statements (at its end, after all objects) put them back as they were at backup time.
-- It also drops what B and the progress log added (they are not in a backup taken before the install, so --clean would
-- leave them behind; the progress log's foreign key on auth.users would even block the re-creation of auth.users).
drop trigger if exists kodhane_saves_z_progress_log on public.kodhane_saves;
drop table if exists public.kodhane_progress_log;
drop function if exists public.kodhane_progress_log_write();
drop function if exists public.kodhane_cleanup_progress_log(integer, integer);
drop trigger if exists kodhane_saves_a_version_guard on public.kodhane_saves;
drop trigger if exists kodhane_saves_v44_stage_id on public.kodhane_saves;
drop function if exists public.kodhane_leaderboard_v7(integer);
drop function if exists public.kodhane_save_version_guard();
drop function if exists public.kodhane_save_v44_stage_id();
alter table if exists public.kodhane_saves drop constraint if exists kodhane_saves_best_stage_id_known;
alter table if exists public.kodhane_saves drop column if exists best_stage_id;
drop function if exists public.kodhane_save_vetted_stage_id(jsonb);
drop function if exists public.kodhane_save_stage_id_checked(jsonb);
drop function if exists public.kodhane_stage_id_max(text, text, text);
drop function if exists public.kodhane_stage_legacy_id(integer);
drop function if exists public.kodhane_stage_at(text);
drop function if exists public.kodhane_stage_rank(text);
drop function if exists public.kodhane_save_format_version(jsonb);
do $prelude$
declare r record;
begin
  for r in
    select pg_get_userbyid(d.defaclrole) as owner, d.defaclnamespace, n.nspname,
           case d.defaclobjtype when 'r' then 'tables' when 'S' then 'sequences' when 'f' then 'functions'
                                when 'T' then 'types' when 'n' then 'schemas' end as kind,
           a.grantee
      from pg_default_acl d left join pg_namespace n on n.oid = d.defaclnamespace
      cross join lateral aclexplode(d.defaclacl) a
     where a.grantee <> d.defaclrole
  loop
    execute format('alter default privileges for role %I %s revoke all on %s from %s', r.owner,
                   case when r.defaclnamespace = 0 then '' else format('in schema %I', r.nspname) end, r.kind,
                   case when r.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(r.grantee)) end);
  end loop;
end $prelude$;
