-- Test-only snapshot helpers (schema t, local throwaway DB). t.snap(ex): md5 + row count per table, rows of user ex left out.
create or replace function t.snap(p_ex uuid default null) returns table (rel text, h text) language plpgsql as $$
declare r record; v text; w text;
begin
  for r in select * from (values ('public.kodhane_saves', 'user_id'), ('public.kodhane_save_backups', 'user_id'),
      ('public.kodhane_profiles', 'user_id'), ('public.kodhane_event_counts', null), ('public.kodhane_game_config', null),
      ('public.acik_ofis_saves', 'user_id'), ('public.acik_ofis_profiles', 'user_id'), ('public.acik_ofis_save_backups', 'user_id'),
      ('public.acik_ofis_game_config', null),
      ('auth.users', 'id'), ('auth.identities', 'user_id'), ('auth.sessions', 'user_id'), ('auth.refresh_tokens', 'user_id'),
      ('auth.flow_state', 'user_id'), ('auth.one_time_tokens', 'user_id'), ('auth.mfa_factors', 'user_id'),
      ('auth.audit_log_entries', '*audit*')) v(rel, col) loop
    continue when to_regclass(r.rel) is null;
    w := case when p_ex is null or r.col is null then 'true'
              when r.col = '*audit*' then format('not coalesce(x.payload ->> ''actor_id'' = %L or x.payload -> ''traits'' ->> ''user_id'' = %L, false)', p_ex, p_ex)
              else format('x.%I::text is distinct from %L', r.col, p_ex::text) end;
    execute format('select md5(coalesce(string_agg(x::text, ''|'' order by x::text), '''')) || '':'' || count(*) from %s x where %s', r.rel, w) into v;
    rel := r.rel; h := v; return next;
  end loop;
end $$;
-- rows of ONE user that kodhane_only keeps (for "kept exactly as before" checks; sessions / refresh tokens are closed)
create or replace function t.snap_of(p_uid uuid) returns table (rel text, h text) language plpgsql as $$
declare r record; v text; w text;
begin
  for r in select * from (values ('public.kodhane_profiles', 'user_id'), ('public.acik_ofis_saves', 'user_id'),
      ('public.acik_ofis_profiles', 'user_id'), ('public.acik_ofis_save_backups', 'user_id'), ('auth.users', 'id'),
      ('auth.identities', 'user_id'), ('auth.mfa_factors', 'user_id'), ('auth.one_time_tokens', 'user_id'),
      ('auth.audit_log_entries', '*audit*')) v(rel, col) loop
    w := case when r.col = '*audit*' then format('coalesce(x.payload ->> ''actor_id'' = %L or x.payload -> ''traits'' ->> ''user_id'' = %L, false)', p_uid, p_uid)
              else format('x.%I::text = %L', r.col, p_uid::text) end;
    execute format('select md5(coalesce(string_agg(x::text, ''|'' order by x::text), '''')) || '':'' || count(*) from %s x where %s', r.rel, w) into v;
    rel := r.rel; h := v; return next;
  end loop;
end $$;
-- Açık Ofis state: data, both Açık Ofis leaderboards (anon), functions + ACLs, triggers
create or replace function t.ao_state() returns table (k text, h text) language sql as $$
  select 'data', md5(coalesce((select string_agg(x::text, '|' order by x::text) from public.acik_ofis_saves x), '') ||
                     coalesce((select string_agg(x::text, '|' order by x::text) from public.acik_ofis_profiles x), '') ||
                     coalesce((select string_agg(x::text, '|' order by x::text) from public.acik_ofis_save_backups x), ''))
  union all select 'lb_kodhane_leaderboard_acik_ofis', md5(coalesce((select string_agg(l::text, '|') from public.kodhane_leaderboard(100, 'acik_ofis') l), ''))
  union all select 'lb_acik_ofis_leaderboard', md5(coalesce((select string_agg(l::text, '|') from public.acik_ofis_leaderboard(100) l), ''))
  union all select 'funcs', md5(string_agg(pg_get_functiondef(oid) || coalesce(proacl::text, ''), '|' order by oid::regprocedure::text))
    from pg_proc where pronamespace = 'public'::regnamespace and proname like 'acik_ofis%'
  union all select 'triggers', md5(string_agg(pg_get_triggerdef(oid), '|' order by tgname)) from pg_trigger
   where not tgisinternal and tgrelid::regclass::text like 'acik_ofis%' $$;
-- leaderboards as sets of nickname|score|stage|status (anon view); lb7 only when package B is applied
create or replace function t.lb() returns setof text language sql as $$
  select l.nickname || '|' || l.score || '|' || l.stage || '|' || l.status from public.kodhane_leaderboard(100) l order by 1 $$;
create or replace function t.lb_ao() returns setof text language sql as $$
  select 'kl|' || l.nickname || '|' || l.score || '|' || l.stage || '|' || l.status from public.kodhane_leaderboard(100, 'acik_ofis') l
  union all select 'al|' || l::text from public.acik_ofis_leaderboard(100) l order by 1 $$;
create or replace function t.lb7() returns setof text language plpgsql as $$
begin
  if to_regprocedure('public.kodhane_leaderboard_v7(integer)') is null then return next 'no v7'; return; end if;
  return query execute 'select l.nickname || ''|'' || l.score || ''|'' || coalesce(l.stage_id, ''-'') || ''|'' || l.status from public.kodhane_leaderboard_v7(100) l order by 1';
end $$;
grant execute on all functions in schema t to public;
