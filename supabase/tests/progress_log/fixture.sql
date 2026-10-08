-- Progress log test fixture (schema t). LOCAL THROWAWAY DB ONLY. Needs fixtures/helpers.sql (t.login, t.ms, users u1..u4).
\set ON_ERROR_STOP on
create table if not exists t.mark (id bigint not null);
insert into t.mark select 0 where not exists (select 1 from t.mark);
grant all on table t.mark to public;
-- a v4.4 save with every logged field at 0
create or replace function t.save0() returns jsonb language sql stable as $$
  select jsonb_build_object('version', 5, 'saveVersion', 5, 'startedAt', t.ms('20 hours'), 'lastSaved', t.ms('1 minute'),
    'money', 10, 'runEarned', 1000, 'cycleEarned', 1000, 'totalEarned', 1000, 'gens', '{"stajyer":5}'::jsonb,
    'shares', 0, 'prestigeCount', 0, 'cycleRounds', 0, 'ipoCount', 0, 'ipoShares', 0, 'ipoSharesEarned', 0, 'tree', '[]'::jsonb,
    'stage', 1, 'stageId', 'ev_ofisi') $$;
-- player write as the CURRENT role (v2.2 protocol: revision + 1): data = (data - p_drop) || p_patch
create or replace function t.kw(p_patch jsonb, p_drop text[] default '{}') returns void language plpgsql as $$
begin
  update public.kodhane_saves set data = (data - p_drop) || p_patch, revision = revision + 1, updated_at = now() where user_id = auth.uid();
  if not found then raise exception 't.kw: no save row for %', auth.uid(); end if;
end $$;
-- first save of the current user (insert, revision 1)
create or replace function t.ki(p_data jsonb) returns void language plpgsql as $$
begin
  insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision) values (auth.uid(), p_data, 5, now(), 1);
end $$;
create or replace function t.setmark() returns void language sql as $$
  update t.mark set id = (select coalesce(max(l.id), 0) from public.kodhane_progress_log l) $$;
-- log rows since the mark: event:field:old>new[:node], '-' = NULL
create or replace function t.since(p_uid uuid default null) returns text language sql stable as $$
  select coalesce(string_agg(l.event || ':' || l.field || ':' || coalesce(l.old_value::text, '-') || '>' || coalesce(l.new_value::text, '-')
                             || coalesce(':' || l.node_id, ''), ' ' order by l.id), '')
    from public.kodhane_progress_log l where l.id > (select m.id from t.mark m) and (p_uid is null or l.user_id = p_uid) $$;
grant execute on all functions in schema t to public;
