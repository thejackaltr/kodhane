-- Kodhane v2.2 save-safety tests. Run by run_v2_2_tests.sh on a THROWAWAY local Postgres after the Kodhane migration,
-- both in a Kodhane-only database (mode a) and in the shared database (mode b). Touches only Kodhane rows (+ auth user u3).
\set ON_ERROR_STOP 1
\set u1 '11111111-1111-4111-8111-111111111111'
\set u2 '22222222-2222-4222-8222-222222222222'
\set u3 '33333333-3333-4333-8333-333333333333'
set client_min_messages = notice;

-- =========================================================== A. backfill + leaderboard
select t.ok((select best_score from public.kodhane_saves where user_id = :'u1') = 500000000, 'K-A1 backfill u1 best_score = 5e8');
select t.ok((select best_score from public.kodhane_saves where user_id = :'u2') = 0, 'K-A2 backfill skips implausible save (u2 1e30 -> 0)');
select t.ok((select bool_and(revision = 0 and not strict_revision) from public.kodhane_saves), 'K-A3 revision starts at 0, lenient');
select t.ok(not exists (select 1 from t.pre_saves p left join public.kodhane_saves s on s.user_id = p.user_id
                        where p.game = 'kodhane' and s.data is distinct from p.data), 'K-A4 migration does not change any save payload');
select t.ok((select best_stage from public.kodhane_saves where user_id = :'u1') = 3 and (select best_stage from public.kodhane_saves where user_id = :'u2') = 0,
            'K-S1 backfill best_stage = current stage if plausible (u1 3, implausible u2 0)');
select t.ok(public.kodhane_save_stage('{"stage":150}') = 99 and public.kodhane_save_stage('{"stage":-3}') = 0 and public.kodhane_save_stage('{"stage":"2"}') = 0
        and public.kodhane_save_stage('{}') = 0 and public.kodhane_save_stage('{"stage":null}') = 0 and public.kodhane_save_stage('{"stage":2.7}') = 2
        and public.kodhane_save_stage('{"stage":1e400}') = 99, 'K-S2 stage clamp 0..99, invalid -> 0 (150->99, -3->0, "2"/missing/null->0, 2.7->2)');
select t.ok(public.kodhane_save_stage_checked('{"stage":3,"totalEarned":1000000}') = 3 and public.kodhane_save_stage_checked('{"stage":5,"totalEarned":1000000}') = 0
        and public.kodhane_save_stage_checked('{"stage":9,"totalEarned":1e30}') = 0 and public.kodhane_save_stage_checked('{"stage":1,"totalEarned":0}') = 0,
            'K-S3 stage must be reachable with totalEarned (game.js STAGES thresholds, max 8)');
select t.login(:'u2');
create temp table lb_k as select * from public.kodhane_leaderboard(50, 'kodhane');
select t.logout();
select t.ok((select score from lb_k where nickname = 'Oyuncu Bir' and status = 'ok') = 500000000 and (select stage from lb_k where nickname = 'Oyuncu Bir') = 3,
            'K-A5 leaderboard: u1 by best_score 5e8, stage = best_stage 3');
select t.ok((select status from lb_k where is_me) = 'pending' and (select score from lb_k where is_me) is null, 'K-A6 implausible u2 still own-row pending (as v5)');
select t.login(null);
create temp table lb_anon as select * from public.kodhane_leaderboard();
create temp table lb_other as select * from public.kodhane_leaderboard(50, 'fenomen');
select t.logout();
select t.ok((select count(*) from lb_anon) = 1 and (select count(*) from lb_other) = 0, 'K-A7 anon default call works (1 listed); unknown game -> empty list');
select t.ok(case when to_regclass('public.acik_ofis_saves') is null
                 then (select count(*) from public.kodhane_leaderboard(50, 'acik_ofis')) = 0 else true end,
            'K-A8 p_game=acik_ofis without any Açık Ofis table: empty list, no error (' || coalesce(to_regclass('public.acik_ofis_saves')::text, 'no acik_ofis_saves here') || ')');

-- =========================================================== B. writes, revisions, the bug
select t.login(:'u1');
select t.push('kodhane_saves', (select data from public.kodhane_saves where user_id = :'u1') || '{"totalEarned":600000000,"cycleEarned":600000000}');
select t.ok((select revision = 1 and best_score = 600000000 and not strict_revision from public.kodhane_saves where user_id = :'u1'),
            'K-B1 legacy push (no revision, score up) accepted, server revision 0->1, best 6e8');
select t.throws(format($q$select t.push('kodhane_saves', %L::jsonb)$q$, jsonb_build_object('version', 4, 'startedAt', t.ms('0 minutes'), 'totalEarned', 0, 'money', 0)),
                'PT409: stale_write', 'K-B2 BUG SCENARIO: late empty save after a local reset (no revision) rejected');
select t.ok((select (data->>'totalEarned')::numeric = 600000000 and best_score = 600000000 from public.kodhane_saves where user_id = :'u1'), 'K-B3 row + best untouched');
select t.push('kodhane_saves', (select data from public.kodhane_saves where user_id = :'u1') || '{"totalEarned":700000000,"cycleEarned":700000000}', 2);
select t.ok((select revision = 2 and best_score = 700000000 and strict_revision from public.kodhane_saves where user_id = :'u1'), 'K-B4 v2.2 push revision 2 accepted, row now strict');
select t.throws(format($q$select t.push('kodhane_saves', %L::jsonb, 1)$q$, (select data from public.kodhane_saves where user_id = :'u1')), 'PT409: stale_revision', 'K-B5 stale revision (1 < 2) -> PT409 stale_revision');
select t.throws(format($q$select t.push('kodhane_saves', %L::jsonb, 2)$q$, (select data from public.kodhane_saves where user_id = :'u1')), 'PT409: stale_revision', 'K-B6 equal revision (2 = 2) rejected');
select t.throws(format($q$select t.push('kodhane_saves', %L::jsonb)$q$, (select data || '{"totalEarned":800000000}' from public.kodhane_saves where user_id = :'u1')), 'PT409: stale_revision', 'K-B7 once strict, legacy write rejected even with a higher score');
select t.throws($q$update public.kodhane_saves set best_score = 1e12 where user_id = auth.uid()$q$, '42501: permission denied%', 'K-B8 client cannot write best_score');
select t.throws($q$update public.kodhane_saves set strict_revision = false where user_id = auth.uid()$q$, '42501: permission denied%', 'K-B9 client cannot clear strict_revision');
select t.throws($q$update public.kodhane_saves set best_stage = 99 where user_id = auth.uid()$q$, '42501: permission denied%', 'K-S4 client cannot write best_stage (update)');
select t.throws($q$insert into public.kodhane_saves (user_id, data, best_stage) values (auth.uid(), '{"totalEarned":1}', 99) on conflict (user_id) do nothing$q$, '42501: permission denied%', 'K-S5 client cannot write best_stage (insert/upsert)');
select t.push('kodhane_saves', (select data from public.kodhane_saves where user_id = :'u1') || '{"stage":1}', 3);
select t.ok((select (data->>'stage')::int = 1 and best_stage = 3 from public.kodhane_saves where user_id = :'u1'), 'K-S6 lower stage stored, best_stage stays 3 (never decreases)');
select t.push('kodhane_saves', (select data from public.kodhane_saves where user_id = :'u1') || '{"stage":4}', 4);
select t.ok((select best_stage from public.kodhane_saves where user_id = :'u1') = 4, 'K-S7 honest stage-up (4 at 7e8 >= 5e7) raises best_stage to 4');
select t.push('kodhane_saves', (select data from public.kodhane_saves where user_id = :'u1') || '{"totalEarned":1000,"runEarned":1000,"cycleEarned":1000}', 5);
select t.ok((select best_score from public.kodhane_saves where user_id = :'u1') = 700000000, 'K-B10 lower score with a NEW revision stored, best_score stays 7e8');
select t.push('kodhane_saves', (select data from public.kodhane_saves where user_id = :'u1') || '{"totalEarned":1e30,"runEarned":1e30,"cycleEarned":1e30,"stage":8}', 6);
select t.ok((select best_score = 700000000 and best_stage = 4 from public.kodhane_saves where user_id = :'u1'), 'K-B11 implausible save raises neither best_score nor best_stage');
select t.push('kodhane_saves', (select data || '{"totalEarned":700000000,"cycleEarned":700000000,"stage":4}' from t.pre_saves where game = 'kodhane' and user_id = :'u1'), 7);
select t.logout();
select t.login(:'u2');
select t.push('kodhane_saves', jsonb_build_object('version',4,'startedAt',t.ms('2 hours'),'totalEarned',2000,'runEarned',2000,'cycleEarned',2000,'money',10,'stage',7), 1);
select t.ok((select best_stage from public.kodhane_saves where user_id = :'u2') = 0, 'K-S8 stage 7 with totalEarned 2000 (plausible score) does not enter best_stage');
select t.push('kodhane_saves', jsonb_build_object('version',4,'startedAt',t.ms('2 hours'),'totalEarned',2000,'runEarned',2000,'cycleEarned',2000,'money',10,'stage',1), 2);
select t.ok((select best_stage = 1 and best_score = 2000 from public.kodhane_saves where user_id = :'u2'), 'K-S9 honest stage 1 at 2000 raises best_stage 0 -> 1');
select t.logout();

-- =========================================================== C. kodhane_reset_save
select t.login(:'u1');
create temp table pre_reset_k as select data, revision, best_score, best_stage from public.kodhane_saves where user_id = :'u1';
create temp table r2 as select public.kodhane_reset_save() as r;
select t.ok(exists (select 1 from public.kodhane_saves where user_id = :'u1'), 'K-C1 reset keeps the row (no DELETE)');
select t.ok((select nickname from public.kodhane_profiles where user_id = :'u1') = 'Oyuncu Bir', 'K-C2 nickname unchanged');
select t.ok((select best_score from public.kodhane_saves where user_id = :'u1') = 700000000 and (select (r->>'best_score')::numeric from r2) = 700000000, 'K-C3 best_score kept (row + return)');
select t.ok((select best_stage from public.kodhane_saves where user_id = :'u1') = 4 and (select (r->>'best_stage')::int from r2) = 4
        and (select best_stage from public.kodhane_save_backups where id = (select (r->>'backup_id')::uuid from r2)) = 4, 'K-S10 best_stage kept after reset (row, return value, backup)');
select t.ok((select revision from public.kodhane_saves where user_id = :'u1') = (select revision + 1 from pre_reset_k)
        and (select (r->>'revision')::bigint from r2) = (select revision + 1 from pre_reset_k), 'K-C4 revision went up (returned + stored)');
select t.ok((select count(*) from public.kodhane_save_backups where id = (select (r->>'backup_id')::uuid from r2) and reason = 'reset'
               and payload = (select data from pre_reset_k) and revision = (select revision from pre_reset_k)) = 1, 'K-C5 backup holds the exact pre-reset save + old revision');
select t.ok((select (d->>'money')::numeric = 0 and (d->>'totalEarned')::numeric = 0 and (d->>'runEarned')::numeric = 0 and (d->>'cycleEarned')::numeric = 0
                and d->'gens' = '{}'::jsonb and d->'upgrades' = '[]'::jsonb and d->'achievements' = '[]'::jsonb
                and (d->>'shares')::int = 0 and (d->>'prestigeCount')::int = 0 and (d->>'cycleRounds')::int = 0
                and (d->>'ipoShares')::int = 0 and (d->>'ipoSharesEarned')::int = 0 and (d->>'ipoCount')::int = 0 and d->'tree' = '[]'::jsonb
                and (d->>'stage')::int = 0 and (d->>'stageBest')::int = 0 and (d->>'cycleStage')::int = 0
                and (d->>'reputation')::int = 0 and (d #>> '{daily,streak}')::int = 0 and d #> '{daily,tasks}' = '[]'::jsonb
                and (d->>'boostLeft')::int = 0 and (d->>'version')::int = 4 and d->'newsSeen' = '["leaderboard"]'::jsonb
              from (select data d from public.kodhane_saves where user_id = :'u1') x),
            'K-C6 progress cleared (money, employees, upgrades, achievements, Yatırım Turu, Halka Arz/Borsa, stage, reputation, streak), newsSeen kept');
select t.throws(format($q$select t.push('kodhane_saves', %L::jsonb, %s)$q$, (select data from pre_reset_k), (select revision + 1 from pre_reset_k)),
                'PT409: stale_revision', 'K-C7 in-flight write with the pre-reset revision rejected after reset');
select t.logout();
select t.ok(public.kodhane_score_plausible((select data from public.kodhane_saves where user_id = :'u1')), 'K-C8 cleared save is plausible');
select t.login(:'u2');
create temp table lb_k2 as select * from public.kodhane_leaderboard(50, 'kodhane');
select t.logout();
select t.ok((select score = 700000000 and stage = 4 and rank = 1 from lb_k2 where nickname = 'Oyuncu Bir'), 'K-C9 after reset u1 keeps 7e8, #1 and stage 4 (best_stage) on the list');
select t.login(null);
select t.throws($q$select public.kodhane_reset_save()$q$, '42501: permission denied for function kodhane_reset_save', 'K-C10 anon cannot call kodhane_reset_save');
select t.throws($q$select public.kodhane_restore_save(gen_random_uuid())$q$, '42501: permission denied for function kodhane_restore_save', 'K-C11 anon cannot call kodhane_restore_save');
select t.logout();
select t.login(:'u1');
select set_config('request.jwt.claim.sub', '', false);
select t.throws($q$select public.kodhane_reset_save()$q$, '42501: not_authenticated', 'K-C12 authenticated role without sub -> not_authenticated');
select t.logout();
select t.ok(to_regprocedure('public.reset_save(text)') is null and to_regprocedure('public.restore_save(uuid)') is null
        and to_regprocedure('public.list_save_backups(text)') is null and to_regclass('public.save_backups') is null and to_regclass('public.game_config') is null,
            'K-C13 no generic reset_save/restore_save/list_save_backups/save_backups/game_config objects');

-- =========================================================== D. kodhane_restore_save
select t.login(:'u1');
create temp table rs2 as select public.kodhane_restore_save((select (r->>'backup_id')::uuid from r2)) as r;
select t.ok((select data from public.kodhane_saves where user_id = :'u1') = (select data from pre_reset_k), 'K-D1 Geri al: payload back to the exact pre-reset state');
select t.ok((select revision from public.kodhane_saves where user_id = :'u1') = (select revision + 2 from pre_reset_k)
        and (select (r->>'revision')::bigint from rs2) = (select revision + 2 from pre_reset_k), 'K-D2 restore bumps revision again');
select t.ok((select reason = 'restore' and (payload->>'totalEarned')::numeric = 0 from public.kodhane_save_backups where id = (select (r->>'backup_id')::uuid from rs2)),
            'K-D3 restore backed up the cleared state first (reason restore)');
select t.ok((select best_score = 700000000 and best_stage = 4 from public.kodhane_saves where user_id = :'u1'), 'K-D4 best_score/best_stage unchanged by restore');
select t.ok((select count(*) from public.kodhane_list_save_backups()) = 2
        and (select stage = 4 and best_stage = 4 from public.kodhane_list_save_backups() where reason = 'reset'), 'K-D5 kodhane_list_save_backups: 2 own backups, stage + best_stage shown');
select t.logout();
select t.login(:'u2');
select t.throws(format($q$select public.kodhane_restore_save(%L)$q$, (select r->>'backup_id' from r2)), 'PT404: backup_not_found', 'K-D6 u2 cannot restore u1''s backup (PT404)');
select t.ok((select count(*) from public.kodhane_save_backups) = 0 and (select count(*) from public.kodhane_list_save_backups()) = 0, 'K-D7 u2 sees none of u1''s backups');
select t.logout();
update public.kodhane_save_backups set created_at = now() - interval '31 days' where id = (select (r->>'backup_id')::uuid from r2);
select t.login(:'u1');
select t.throws(format($q$select public.kodhane_restore_save(%L)$q$, (select r->>'backup_id' from r2)), 'PT404: backup_not_found', 'K-D8 expired (31 d) backup cannot be restored');
select t.ok(not exists (select 1 from public.kodhane_save_backups where id = (select (r->>'backup_id')::uuid from r2)), 'K-D9 expired backup hidden from the owner');
select t.logout();
update public.kodhane_save_backups set created_at = now() - interval '29 days' where id = (select (r->>'backup_id')::uuid from r2);
select t.login(:'u1');
select public.kodhane_reset_save();
create temp table rs3 as select public.kodhane_restore_save((select (r->>'backup_id')::uuid from r2)) as r;
select t.ok((select data from public.kodhane_saves where user_id = :'u1') = (select data from pre_reset_k), 'K-D10 29-day-old backup restores the full save');
select t.logout();

-- =========================================================== E. RLS / privileges
select t.login(:'u2');
select t.ok((select count(*) from public.kodhane_saves where user_id = :'u1') = 0 and (select count(*) from public.kodhane_saves) = 1, 'K-E1 u2 reads only its own row');
do $$ declare n int; begin
  update public.kodhane_saves set data = '{"totalEarned":1}' where user_id = '11111111-1111-4111-8111-111111111111';
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'K-E2 u2 update of u1''s row affects 0 rows');
end $$;
select t.throws(format($q$insert into public.kodhane_saves (user_id, data) values (%L, '{"totalEarned":5}')$q$, :'u3'), '42501: new row violates row-level security policy%', 'K-E3 u2 insert as another user rejected');
select t.throws(format($q$select t.push('kodhane_saves', '{"totalEarned":5}'::jsonb, 99, %L)$q$, :'u1'), '42501: %', 'K-E4 u2 upsert onto u1''s row rejected');
select t.throws($q$delete from public.kodhane_saves where user_id = auth.uid()$q$, '42501: permission denied for table kodhane_saves', 'K-E5 client DELETE blocked (old Kaydı sıfırla path)');
select t.ok(exists (select 1 from public.kodhane_saves where user_id = :'u2'), 'K-E6 u2 row still exists');
select t.throws($q$insert into public.kodhane_save_backups (user_id, revision, payload, reason) values (auth.uid(), 1, '{}', 'manual')$q$, '42501: permission denied%', 'K-E7 client cannot insert backups');
select t.throws($q$update public.kodhane_save_backups set best_score = 1e20$q$, '42501: permission denied%', 'K-E8 client cannot update backups');
select t.throws($q$delete from public.kodhane_save_backups$q$, '42501: permission denied%', 'K-E9 client cannot delete backups');
select t.throws($q$select * from public.kodhane_game_config$q$, '42501: permission denied%', 'K-E10 client cannot read kodhane_game_config');
select t.throws($q$select public.kodhane_cleanup_save_backups()$q$, '42501: permission denied%', 'K-E11 client cannot run cleanup');
select t.throws(format($q$select public.kodhane_save_backups_trim(%L)$q$, :'u1'), '42501: permission denied%', 'K-E12 client cannot trim anyone''s backups');
select t.throws($q$select public.kodhane_save_vetted_score('{}')$q$, '42501: permission denied%', 'K-E13 helpers not exposed');
select t.throws($q$select public.kodhane_score_plausible('{}')$q$, '42501: permission denied%', 'K-E14 plausibility rule still service_role only');
select t.logout();
select t.login(null);
select t.throws($q$select * from public.kodhane_saves$q$, '42501: permission denied%', 'K-E15 anon cannot read saves');
select t.throws($q$select * from public.kodhane_save_backups$q$, '42501: permission denied%', 'K-E16 anon cannot read backups');
select t.throws($q$select * from public.kodhane_list_save_backups()$q$, '42501: permission denied%', 'K-E17 anon cannot list backups');
select t.logout();

-- =========================================================== F. strict mode
update public.kodhane_game_config set value = '"strict"' where key = 'revision_mode';
select t.login(:'u3');
select t.push('kodhane_saves', jsonb_build_object('version',4,'startedAt',t.ms('1 hour'),'totalEarned',500,'runEarned',500,'cycleEarned',500));
select t.throws(format($q$select t.push('kodhane_saves', %L::jsonb)$q$, (select data || '{"totalEarned":600,"runEarned":600,"cycleEarned":600}' from public.kodhane_saves where user_id = :'u3')),
                'PT409: stale_revision', 'K-F1 strict: legacy write (no new revision) rejected even with a higher score on a never-strict row');
select t.push('kodhane_saves', (select data || '{"totalEarned":600,"runEarned":600,"cycleEarned":600}' from public.kodhane_saves where user_id = :'u3'), (select revision + 1 from public.kodhane_saves where user_id = :'u3'));
select t.ok((select best_score from public.kodhane_saves where user_id = :'u3') = 600, 'K-F2 strict: revision + 1 accepted');
select t.logout();
update public.kodhane_game_config set value = '"lenient"' where key = 'revision_mode';

-- =========================================================== G. best survives admin deletes
select t.as_service();
delete from public.kodhane_saves where user_id = :'u2';
select t.logout();
select t.ok((select count(*) from public.kodhane_save_backups where user_id = :'u2' and reason = 'delete' and best_score = 2000 and best_stage = 1) = 1, 'K-G1 admin delete leaves a delete backup with best_score + best_stage');
select t.login(:'u2');
select t.push('kodhane_saves', jsonb_build_object('version', 4, 'startedAt', t.ms('0 minutes'), 'totalEarned', 10, 'runEarned', 10, 'cycleEarned', 10));
select t.ok((select best_score = 2000 and best_stage = 1 from public.kodhane_saves where user_id = :'u2'), 'K-G2 re-created row gets best_score + best_stage back from its backups');
select t.logout();

-- =========================================================== H. retention / cleanup / cap / cron / cascade
insert into public.kodhane_save_backups (user_id, revision, payload, best_score, reason, created_at) values
  (:'u1', 0, '{"totalEarned":1}', 1, 'manual', now() - interval '40 days'),
  (:'u1', 0, '{"totalEarned":2}', 2, 'manual', now() - interval '30 days 1 minute'),
  (:'u1', 0, '{"totalEarned":3}', 3, 'manual', now() - interval '5 days');
create temp table h_before as select id, created_at from public.kodhane_save_backups;
select t.as_service();
create temp table h1 as select public.kodhane_cleanup_save_backups() as n;
select t.logout();
select t.ok((select n from h1) = (select count(*) from h_before where created_at <= now() - interval '30 days') and (select n from h1) >= 2,
            'K-H1 cleanup deleted exactly the expired rows (' || (select n from h1) || ')');
select t.ok(not exists (select 1 from public.kodhane_save_backups where created_at <= now() - interval '30 days')
        and (select count(*) from public.kodhane_save_backups) = (select count(*) from h_before where created_at > now() - interval '30 days'), 'K-H2 nothing younger than 30 days deleted');
update public.kodhane_game_config set value = '3' where key = 'backup_retention_days';
select t.as_service();
select public.kodhane_cleanup_save_backups();
select t.logout();
select t.ok(not exists (select 1 from public.kodhane_save_backups where payload = '{"totalEarned":3}'), 'K-H3 retention read from kodhane_game_config (3 days -> 5-day backup deleted)');
update public.kodhane_game_config set value = '30' where key = 'backup_retention_days';
update public.kodhane_game_config set value = '3' where key = 'backup_max_per_user';
select t.login(:'u1');
select public.kodhane_reset_save(); select public.kodhane_reset_save(); select public.kodhane_reset_save(); select public.kodhane_reset_save();
select t.ok((select count(*) from public.kodhane_save_backups) = 3, 'K-H4 per-player cap (3) trims the oldest backups');
select t.ok((select best_score = 700000000 and best_stage = 4 from public.kodhane_saves where user_id = :'u1'), 'K-H5 best_score + best_stage survive 4 more resets');
select t.logout();
update public.kodhane_game_config set value = '50' where key = 'backup_max_per_user';
select t.ok(not exists (select 1 from pg_extension where extname = 'pg_cron'), 'K-H6 the migration alone does not enable pg_cron / schedule anything');
select t.login(:'u3'); select public.kodhane_reset_save(); select t.logout();
delete from auth.users where id = :'u3';
select t.ok(not exists (select 1 from public.kodhane_save_backups where user_id = :'u3') and not exists (select 1 from public.kodhane_saves where user_id = :'u3'),
            'K-H7 deleting the auth user cascades save + backups, no delete-backup left');
