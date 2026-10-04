-- Test helpers (schema t) + fake auth users. LOCAL THROWAWAY DB ONLY. Game data: seed_kodhane.sql / seed_acik_ofis.sql.
create schema if not exists t;
create table if not exists t.results (n serial primary key, name text not null, pass boolean not null, info text);
grant usage on schema t to public;
grant all on table t.results to public;
grant all on sequence t.results_n_seq to public;

create or replace function t.ok(p_pass boolean, p_name text, p_info text default null) returns void language plpgsql as $$
begin
  insert into t.results (name, pass, info) values (p_name, coalesce(p_pass, false), p_info);
  raise notice '% % %', case when coalesce(p_pass, false) then 'PASS' else 'FAIL' end, p_name, coalesce(' -- ' || p_info, '');
end $$;

-- expects p_sql to fail with an error whose "SQLSTATE: message" matches p_like
create or replace function t.throws(p_sql text, p_like text, p_name text) returns void language plpgsql as $$
declare st text; msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform t.ok((st || ': ' || msg) like p_like, p_name, st || ': ' || msg);
    return;
  end;
  perform t.ok(false, p_name, 'no error raised');
end $$;

-- "log in" like PostgREST does for a user JWT (role authenticated + request.jwt.claim.sub); null uid = anon
create or replace function t.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', case when p_uid is null then 'anon' else 'authenticated' end, false);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
end $$;
create or replace function t.logout() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('role', 'none', false);   -- = RESET ROLE (back to postgres)
end $$;
create or replace function t.as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('role', 'service_role', false);
end $$;

-- the exact statement PostgREST runs for POST /rest/v1/<tbl>?on_conflict=user_id with
-- Prefer: resolution=merge-duplicates (supabase-js .upsert(..., {onConflict:'user_id'}) is the same).
-- p_rev null = today's clients (no revision in the body). Runs as the CURRENT role (RLS + grants apply).
create or replace function t.push(p_tbl text, p_data jsonb, p_rev bigint default null, p_uid uuid default null) returns void
language plpgsql as $$
begin
  if p_rev is null then
    execute format('insert into public.%I (user_id, data, save_version, updated_at) values ($1, $2, 2, now())
                    on conflict (user_id) do update set user_id = excluded.user_id, data = excluded.data,
                    save_version = excluded.save_version, updated_at = excluded.updated_at', p_tbl)
      using coalesce(p_uid, auth.uid()), p_data;
  else
    execute format('insert into public.%I (user_id, data, save_version, updated_at, revision) values ($1, $2, 2, now(), $3)
                    on conflict (user_id) do update set user_id = excluded.user_id, data = excluded.data,
                    save_version = excluded.save_version, updated_at = excluded.updated_at, revision = excluded.revision', p_tbl)
      using coalesce(p_uid, auth.uid()), p_data, p_rev;
  end if;
end $$;
grant execute on all functions in schema t to public;

-- ms timestamps like the games write them
create or replace function t.ms(p interval) returns numeric language sql stable as $$ select floor(extract(epoch from now() - p) * 1000) $$;

-- ---------------------------------------------------------------- fake auth users (u1, u2 play both games; u3/u4 = account-deletion tests)
insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'u1-v22-test@example.invalid'),
  ('22222222-2222-4222-8222-222222222222', 'u2-v22-test@example.invalid'),
  ('33333333-3333-4333-8333-333333333333', 'u3-v22-test@example.invalid'),
  ('44444444-4444-4444-8444-444444444444', 'u4-v22-test@example.invalid');
create table t.pre_saves (game text not null, user_id uuid not null, data jsonb not null);
grant select on table t.pre_saves to public;
