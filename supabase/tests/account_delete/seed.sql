-- Account-deletion test seed. LOCAL THROWAWAY DB ONLY. Needs fixtures/helpers.sql (schema t, auth users u1..u4).
-- u1 = mode=full target, both games (Kodhane save + 'reset' backup + profile; Açık Ofis save + backup + AO profile;
--      auth extras: identity, session, refresh tokens, flow state, one-time token, MFA factor; audit log entries).
-- u2 = bystander in both games (+ audit entries, one admin entry about u2).
-- u3 = mode=kodhane_only target, both games (Kodhane save + backup + profile = also its Açık Ofis nickname; AO save + profile; audit).
-- u4 = Kodhane only (second full target: re-signup with a new id and the same e-mail).
\set ON_ERROR_STOP on
create or replace function t.ksave(p_total numeric, p_stage int default 3) returns jsonb language sql stable as $$
  select jsonb_build_object('version', 4, 'startedAt', t.ms('20 hours'), 'lastSaved', t.ms('1 minute'),
    'money', 1500000, 'runEarned', least(p_total, 200000000), 'cycleEarned', p_total, 'totalEarned', p_total,
    'gens', '{"stajyer":25,"junior":10}'::jsonb, 'shares', 2, 'prestigeCount', 2, 'cycleRounds', 2, 'ipoShares', 0,
    'ipoSharesEarned', 0, 'ipoCount', 0, 'stage', p_stage, 'stageBest', p_stage, 'cycleStage', p_stage) $$;
create or replace function t.kpush(p_data jsonb) returns void language plpgsql as $$
begin   -- the v2.2 client upsert (revision = server revision + 1), as the logged-in user
  insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision)
  values (auth.uid(), p_data, 4, now(), coalesce((select s.revision + 1 from public.kodhane_saves s where s.user_id = auth.uid()), 1))
  on conflict (user_id) do update set data = excluded.data, save_version = excluded.save_version, updated_at = excluded.updated_at,
    revision = excluded.revision;
end $$;
grant execute on all functions in schema t to public;

insert into public.kodhane_profiles (user_id, nickname) values
  ('11111111-1111-4111-8111-111111111111', 'Silinecek Bir'), ('22222222-2222-4222-8222-222222222222', 'Kalan İki'),
  ('33333333-3333-4333-8333-333333333333', 'Iki Oyunlu Uc'), ('44444444-4444-4444-8444-444444444444', 'Kalan Dort');
select t.login('11111111-1111-4111-8111-111111111111');
select t.kpush(t.ksave(500000000));
select public.kodhane_reset_save();                  -- 'reset' backup with best_score 5e8
select t.kpush(t.ksave(1000, 1));                    -- current save small, best_score stays 5e8
select t.login('22222222-2222-4222-8222-222222222222');
select t.kpush(t.ksave(600000000));
select t.login('33333333-3333-4333-8333-333333333333');
select t.kpush(t.ksave(450000000));
select public.kodhane_reset_save();                  -- u3: 'reset' backup, best_score stays 4.5e8
select t.kpush(t.ksave(3000, 1));
select t.login('44444444-4444-4444-8444-444444444444');
select t.kpush(t.ksave(800000000));
select public.kodhane_reset_save();
select t.kpush(t.ksave(2000, 1));
select t.logout();

-- Açık Ofis rows (u1 full target, u2 bystander, u3 kodhane_only target); written as admin, the AO triggers still run
insert into public.acik_ofis_saves (user_id, data, save_version)
select u, jsonb_build_object('v', 2, 'startedAt', t.ms('10 hours'), 'lastSaved', t.ms('2 minutes'), 'money', 500, 'totalEarned', te,
         'stage', 1, 'flags', '{"stagesCounted":[0,1]}'::jsonb), 2
  from (values ('11111111-1111-4111-8111-111111111111'::uuid, 70000), ('22222222-2222-4222-8222-222222222222', 90000),
               ('33333333-3333-4333-8333-333333333333', 80000)) v(u, te);
insert into public.acik_ofis_profiles (user_id, nickname) values ('11111111-1111-4111-8111-111111111111', 'AO Silinecek Bir'),
  ('22222222-2222-4222-8222-222222222222', 'AO Kalan İki'), ('33333333-3333-4333-8333-333333333333', 'AO Uc');
insert into public.acik_ofis_save_backups (user_id, revision, payload, best_score, best_stage, reason)
  select user_id, 0, data, 0, 0, 'manual' from public.acik_ofis_saves
   where user_id in ('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222');

-- GoTrue audit log: own actions (payload.actor_id) and admin actions on the user (payload.traits.user_id)
insert into auth.audit_log_entries (instance_id, id, payload, created_at, ip_address)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(),
       json_build_object('action', a, 'actor_id', actor, 'actor_username', un, 'actor_via_sso', false, 'log_type', lt,
                         'traits', case when tu is null then null else json_build_object('user_id', tu, 'user_email', te, 'provider', 'email') end),
       now(), '127.0.0.1'
  from (values
    ('user_signedup', '00000000-0000-0000-0000-000000000000', 'service_role', 'team', '11111111-1111-4111-8111-111111111111', 'u1-v22-test@example.invalid'),
    ('login', '11111111-1111-4111-8111-111111111111', 'u1-v22-test@example.invalid', 'account', null, null),
    ('token_refreshed', '11111111-1111-4111-8111-111111111111', 'u1-v22-test@example.invalid', 'token', null, null),
    ('user_signedup', '00000000-0000-0000-0000-000000000000', 'service_role', 'team', '22222222-2222-4222-8222-222222222222', 'u2-v22-test@example.invalid'),
    ('login', '22222222-2222-4222-8222-222222222222', 'u2-v22-test@example.invalid', 'account', null, null),
    ('login', '33333333-3333-4333-8333-333333333333', 'u3-v22-test@example.invalid', 'account', null, null),
    ('login', '44444444-4444-4444-8444-444444444444', 'u4-v22-test@example.invalid', 'account', null, null)) v(a, actor, un, lt, tu, te);

-- auth extras for u1 (FK-cascaded and FK-less), one identity for u2
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('11111111-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111', '{"sub":"11111111-1111-4111-8111-111111111111"}', 'email'),
  ('22222222-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', '{"sub":"22222222-2222-4222-8222-222222222222"}', 'email');
insert into auth.sessions (id, user_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111'),
  ('aaaaaaaa-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222');
insert into auth.refresh_tokens (token, user_id, session_id) values
  ('kd-test-rt-1', '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000001'),
  ('kd-test-rt-2', '11111111-1111-4111-8111-111111111111', null),                 -- no session: FK-less, deleted explicitly
  ('kd-test-rt-3', '22222222-2222-4222-8222-222222222222', 'aaaaaaaa-0000-4000-8000-000000000002');
-- u3 (kodhane_only target): two sessions, three refresh tokens (two session-bound, one without a session)
insert into auth.sessions (id, user_id) values ('aaaaaaaa-0000-4000-8000-000000000003', '33333333-3333-4333-8333-333333333333'),
  ('aaaaaaaa-0000-4000-8000-000000000004', '33333333-3333-4333-8333-333333333333');
insert into auth.refresh_tokens (token, user_id, session_id) values
  ('kd-test-rt-4', '33333333-3333-4333-8333-333333333333', 'aaaaaaaa-0000-4000-8000-000000000003'),
  ('kd-test-rt-5', '33333333-3333-4333-8333-333333333333', 'aaaaaaaa-0000-4000-8000-000000000004'),
  ('kd-test-rt-6', '33333333-3333-4333-8333-333333333333', null);
insert into auth.flow_state (id, user_id, provider_type, authentication_method) values
  ('bbbbbbbb-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'email', 'magiclink');
insert into auth.one_time_tokens (id, user_id, token_type, token_hash, relates_to) values
  ('cccccccc-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'confirmation_token', 'kd-test-hash', 'u1-v22-test@example.invalid');
insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at) values
  ('dddddddd-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'totp', 'unverified', now(), now());
