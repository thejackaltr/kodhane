-- Rehearsal seed on top of the pseudonymized live copy (LOCAL THROWAWAY DB ONLY): players in every stored format the B
-- guard distinguishes, written through the normal v2.2 path (triggers on). Ids 7e570000-..., nicknames 'Prova N'.
\set ON_ERROR_STOP on
create temp table _seed(n int, uid uuid, data jsonb);
insert into _seed
select n, ('7e570000-0000-4000-8000-00000000000' || n)::uuid,
       jsonb_build_object('version', 4, 'startedAt', floor(extract(epoch from now() - interval '20 hours') * 1000),
         'lastSaved', floor(extract(epoch from now()) * 1000), 'totalEarned', te, 'runEarned', te, 'cycleEarned', te,
         'shares', 0, 'prestigeCount', 0, 'cycleRounds', 0, 'ipoCount', 0, 'ipoSharesEarned', 0, 'stage', 3) || extra
  from (values
    (1, 5e6::numeric,   '{"version": 5, "saveVersion": 5, "clientVersion": "4.4.2", "stageId": "ajans"}'::jsonb),  -- v4.4.2
    (2, 4e6,            '{"version": 5, "saveVersion": 5, "stageId": "ajans"}'),                            -- v4.4.0 / v4.4.1
    (3, 3e6,            '{"saveVersion": 4}'),                                                              -- v4.3.1
    (4, 2e6,            '{}'),                                                                              -- v4.3.0
    (5, 1e15,           '{"version": 5, "saveVersion": 5, "clientVersion": "4.4.2"}')                       -- implausible
  ) v(n, te, extra);
insert into auth.users (id, aud, role, created_at, updated_at) select uid, 'authenticated', 'authenticated', now(), now() from _seed;
insert into public.kodhane_profiles (user_id, nickname) select uid, 'Prova ' || n from _seed;
insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision) select uid, data, 2, now(), 1 from _seed;
