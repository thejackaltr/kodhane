-- Loss report (Kayıp bildir) test fixture (schema t). LOCAL THROWAWAY DB ONLY. Needs fixtures/helpers.sql, account_delete/seed.sql
-- and progress_log/fixture.sql (t.login, t.kw, t.ki, t.save0, users u1..u4).
\set ON_ERROR_STOP on
-- t.err(sql): 'none' or 'SQLSTATE|message|detail' of the statement, run as the CURRENT role (rolled back on error)
create or replace function t.err(p_sql text) returns text language plpgsql as $$
declare st text; msg text; det text;
begin
  execute p_sql;
  return 'none';
exception when others then
  get stacked diagnostics st = returned_sqlstate, msg = message_text, det = pg_exception_detail;
  return st || '|' || msg || '|' || coalesce(det, '');
end $$;
-- named points in time (clock_timestamp: later than every earlier transaction's now())
create table if not exists t.tm (name text primary key, at timestamptz not null);
grant all on table t.tm to public;
create or replace function t.tmark(p_name text) returns timestamptz language sql as $$
  insert into t.tm values (p_name, clock_timestamp()) on conflict (name) do update set at = excluded.at returning at $$;
create or replace function t.at(p_name text) returns timestamptz language sql stable as $$ select at from t.tm where name = p_name $$;
-- the save's logged fields as text (fixed order): shares/prestigeCount/cycleRounds/ipoCount/ipoShares/ipoSharesEarned/tree
create or replace function t.lf(p_uid uuid) returns text language sql stable as $$
  select concat_ws('/', s.data ->> 'shares', s.data ->> 'prestigeCount', s.data ->> 'cycleRounds', s.data ->> 'ipoCount',
                   s.data ->> 'ipoShares', s.data ->> 'ipoSharesEarned', coalesce(s.data -> 'tree', '[]')::text)
    from public.kodhane_saves s where s.user_id = p_uid $$;
-- md5 of everything about a save (data + columns) and of the player's backups / log rows
create or replace function t.save_md5(p_uid uuid) returns text language sql stable as $$
  select md5(coalesce((select row(s.*)::text from public.kodhane_saves s where s.user_id = p_uid), '-')
          || coalesce((select string_agg(row(b.*)::text, '|' order by b.created_at, b.id) from public.kodhane_save_backups b where b.user_id = p_uid), '-')
          || coalesce((select string_agg(row(l.*)::text, '|' order by l.id) from public.kodhane_progress_log l where l.user_id = p_uid), '-')) $$;
create or replace function t.others_md5(p_uid uuid) returns text language sql stable as $$
  select md5(coalesce((select string_agg(row(s.*)::text, '|' order by s.user_id) from public.kodhane_saves s where s.user_id <> p_uid), '-')
          || coalesce((select string_agg(row(l.*)::text, '|' order by l.id) from public.kodhane_progress_log l where l.user_id <> p_uid), '-')) $$;
grant execute on all functions in schema t to public;
