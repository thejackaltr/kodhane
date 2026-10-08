-- Kodhane seed (needs helpers.sql + kodhane_profiles/kodhane_saves). LOCAL THROWAWAY DB ONLY.
insert into public.kodhane_profiles (user_id, nickname) values
  ('11111111-1111-4111-8111-111111111111', 'Oyuncu Bir'),
  ('22222222-2222-4222-8222-222222222222', 'Oyuncu İki');

-- u1 Kodhane: plausible (2 Yatırım Turu, no Halka Arz), with progress in every field reset must clear
insert into public.kodhane_saves (user_id, data, save_version) values ('11111111-1111-4111-8111-111111111111',
  jsonb_build_object('version', 4, 'startedAt', t.ms('20 hours'), 'lastSaved', t.ms('1 minute'),
    'money', 1500000, 'runEarned', 200000000, 'cycleEarned', 500000000, 'totalEarned', 500000000,
    'gens', '{"stajyer":25,"junior":10}'::jsonb, 'upgrades', '["u1","u2"]'::jsonb, 'achievements', '["a1","a2","a3"]'::jsonb,
    'shares', 2, 'prestigeCount', 2, 'cycleRounds', 2, 'ipoShares', 0, 'ipoSharesEarned', 0, 'ipoCount', 0, 'tree', '[]'::jsonb,
    'stage', 3, 'stageBest', 3, 'cycleStage', 3, 'reputation', 42, 'boostLeft', 30,
    'daily', '{"date":"2026-09-28","tasks":[{"id":"t1"}],"streak":3,"best":4,"lastComplete":"2026-09-27","allDone":false,"daysCompleted":5}'::jsonb,
    'newsSeen', '["leaderboard"]'::jsonb, 'revisions', 7), 4);
-- u2 Kodhane: IMPLAUSIBLE (1e30 on a brand-new save) -> 'pending' today, must not enter best_score
insert into public.kodhane_saves (user_id, data, save_version) values ('22222222-2222-4222-8222-222222222222',
  jsonb_build_object('version', 4, 'startedAt', t.ms('1 minute'), 'lastSaved', t.ms('0 minutes'), 'totalEarned', 1e30, 'runEarned', 1e30, 'money', 5), 4);

insert into t.pre_saves select 'kodhane', user_id, data from public.kodhane_saves;
