-- Fixture for the S group of run_kodhane_score_rule_tests.sh (LOCAL test DB with package B, BEFORE the v4.5 install):
-- six players around the new stage asama_1e21. sr_test.s21(stage, totalEarned) = a v4.5 save at that stage (12 h old,
-- one Halka Arz; plausible under v4.5 at 1.15e21 for asama_1e21, never under v4.4b).
create schema if not exists sr_test;
create or replace function sr_test.s21(p_stage text, p_te numeric) returns jsonb language sql stable as $$
  select jsonb_build_object('saveVersion', 5, 'version', 5, 'totalEarned', p_te, 'runEarned', 0, 'cycleEarned', p_te, 'shares', 5441797,
    'prestigeCount', 22, 'cycleRounds', 19, 'ipoCount', 1, 'ipoSharesEarned', 1, 'stageId', p_stage, 'stageBestId', p_stage, 'cycleStageId', p_stage,
    'startedAt', floor(extract(epoch from now() - interval '12 hours') * 1000), 'lastSaved', floor(extract(epoch from now()) * 1000))
$$;
insert into auth.users (id, aud, role, created_at, updated_at)
  select ('5e210000-0000-4000-8000-00000000000' || c)::uuid, 'authenticated', 'authenticated', now(), now() from unnest(array['a','b','c','d','e','f','9']) c;
insert into public.kodhane_profiles (user_id, nickname)
  select ('5e210000-0000-4000-8000-00000000000' || c)::uuid, 'SR Aşama ' || upper(c) from unnest(array['a','b','c','d','e','f','9']) c;
-- A: was yapay_zeka_lab (plausible), now at asama_1e21 (implausible under B: best_stage_id stays yapay_zeka_lab)
insert into public.kodhane_saves (user_id, data, revision) values ('5e210000-0000-4000-8000-00000000000a', sr_test.s21('yapay_zeka_lab', 1.149894005101156e21), 1);
update public.kodhane_saves set data = sr_test.s21('asama_1e21', 1.149894005101156e21), revision = 2 where user_id = '5e210000-0000-4000-8000-00000000000a';
-- B: first save already at asama_1e21: best_stage_id NULL
insert into public.kodhane_saves (user_id, data, revision) values ('5e210000-0000-4000-8000-00000000000b', sr_test.s21('asama_1e21', 1.149894005101156e21), 1);
-- C: was teknoloji_devi, now at asama_1e21
insert into public.kodhane_saves (user_id, data, revision) values ('5e210000-0000-4000-8000-00000000000c', sr_test.s21('teknoloji_devi', 1.149894005101156e21), 1);
update public.kodhane_saves set data = sr_test.s21('asama_1e21', 1.149894005101156e21), revision = 2 where user_id = '5e210000-0000-4000-8000-00000000000c';
-- D: yapay_zeka_lab; reaches asama_1e21 only AFTER the install (trigger path)
insert into public.kodhane_saves (user_id, data, revision) values ('5e210000-0000-4000-8000-00000000000d', sr_test.s21('yapay_zeka_lab', 1.149894005101156e21), 1);
-- E: best_stage_id already mars_ofisi (higher): not touched
insert into public.kodhane_saves (user_id, data, revision) values ('5e210000-0000-4000-8000-00000000000e', sr_test.s21('asama_1e21', 1.149894005101156e21), 1);
set session_replication_role = replica;
update public.kodhane_saves set best_stage_id = 'mars_ofisi' where user_id = '5e210000-0000-4000-8000-00000000000e';
set session_replication_role = origin;
-- F: claims asama_1e21 with 9e20 (< 1e21): not reachable, not touched
insert into public.kodhane_saves (user_id, data, revision) values ('5e210000-0000-4000-8000-00000000000f', sr_test.s21('asama_1e21', 9e20), 1);
-- (…9: no save yet; inserted at asama_1e21 after the install: INSERT path of the log trigger)
