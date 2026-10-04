-- Package B tests (stage IDs + save-version guard). LOCAL THROWAWAY DB ONLY (run_v4_4b_tests.sh).
-- Needs fixtures/helpers.sql (t.ok, t.throws, t.login, t.logout, t.as_service, users u1..u4), packages A + B applied.
\set ON_ERROR_STOP on
\set u1 '11111111-1111-4111-8111-111111111111'
\set u2 '22222222-2222-4222-8222-222222222222'
\set u3 '33333333-3333-4333-8333-333333333333'
-- the statement PostgREST runs for supabase-js upsert(row, {onConflict:'user_id'}) with the v4.3/v4.4 cloud.js row
create or replace function t.up(p_data jsonb, p_rev bigint default null) returns void language plpgsql as $$
begin
  insert into public.kodhane_saves (user_id, data, save_version, updated_at, revision)
  values (auth.uid(), p_data, 2, now(),
          coalesce(p_rev, (select s.revision + 1 from public.kodhane_saves s where s.user_id = auth.uid()), 1))
  on conflict (user_id) do update set data = excluded.data, save_version = excluded.save_version, updated_at = excluded.updated_at,
    revision = excluded.revision;
end $$;
grant execute on function t.up(jsonb, bigint) to public;
create or replace function t.save(p_total numeric, p_extra jsonb default '{}') returns jsonb language sql stable as $$
  select jsonb_build_object('version', 4, 'startedAt', floor(extract(epoch from now() - interval '20 hours') * 1000),
    'lastSaved', floor(extract(epoch from now()) * 1000), 'totalEarned', p_total, 'runEarned', p_total, 'cycleEarned', p_total,
    'shares', 0, 'prestigeCount', 0, 'cycleRounds', 0, 'ipoCount', 0, 'ipoSharesEarned', 0, 'stage', 3) || p_extra $$;
grant execute on function t.save(numeric, jsonb) to public;
insert into public.kodhane_profiles (user_id, nickname) values (:'u1', 'Test Bir'), (:'u2', 'Test İki'), (:'u3', 'Test Üç')
  on conflict do nothing;

-- ---------------------------------------------------------------- V: save-version guard
select t.login(:'u1');
select t.up(t.save(2e6, '{"saveVersion": 5, "version": 5, "stageId": "ajans"}'), 1);
select t.throws($q$select t.up(t.save(3e6, '{"saveVersion": 4}'), 2)$q$, 'PT426: save_version_too_old', 'V1 v4.3.1 write (saveVersion 4) over a v4.4 save (5) -> PT426');
select t.throws($q$select t.up(t.save(3e6), 2)$q$, 'PT426: save_version_too_old', 'V2 v4.3.0 write (no saveVersion = 0) over a v4.4 save -> PT426');
do $d$ declare det text; hint text; begin
  begin perform t.up(t.save(3e6), 2);
  exception when sqlstate 'PT426' then get stacked diagnostics det = pg_exception_detail, hint = pg_exception_hint; end;
  perform t.ok(det = 'sent saveVersion 0, stored saveVersion 5' and hint like 'This game version is older than the cloud save.%', 'V3 detail / hint name both versions', det);
end $d$;
select t.ok((select revision = 1 and (data->>'totalEarned')::numeric = 2e6 and data->>'saveVersion' = '5' from public.kodhane_saves where user_id = :'u1'),
  'V4 refused writes change nothing (data, revision)');
select t.up(t.save(3e6, '{"saveVersion": 5, "version": 5}'), 2);
select t.up(t.save(4e6, '{"saveVersion": 6, "version": 6}'), 3);
select t.ok((select revision = 3 and data->>'saveVersion' = '6' from public.kodhane_saves where user_id = :'u1'), 'V5 same and higher saveVersion accepted (5 -> 5 -> 6)');
select t.logout();
select t.login(:'u2');
select t.up(t.save(2e6), 1);
select t.up(t.save(2.5e6), 2);
select t.ok((select revision = 2 from public.kodhane_saves where user_id = :'u2'), 'V6 no saveVersion over no saveVersion accepted (v4.3.0 -> v4.3.0)');
select t.up(t.save(3e6, '{"saveVersion": 4}'), 3);
select t.up(t.save(3.5e6), 4);
select t.ok((select revision = 4 and (data->>'totalEarned')::numeric = 3.5e6 and data->>'saveVersion' is null from public.kodhane_saves where user_id = :'u2'),
  'V7 (a) v4.3.0 write (no saveVersion = 0) over a v4.3.1 save (4) accepted: format 4 saves are not guarded');
select t.up(t.save(3.6e6, '{"saveVersion": 4}'), 5);
select t.up(t.save(3.7e6, '{"saveVersion": 4}'), 6);
select t.ok((select revision = 6 and data->>'saveVersion' = '4' from public.kodhane_saves where user_id = :'u2'), 'V7b v4.3.1 write (4) over a v4.3.1 save (4) accepted');
select t.up(t.save(4e6, '{"saveVersion": 5, "version": 5}'), 7);
select t.ok((select revision = 7 from public.kodhane_saves where user_id = :'u2'), 'V8 v4.4 write over a v4.3.1 save accepted');
select t.throws($q$select t.up(t.save(4.1e6, '{"saveVersion": 4, "version": 4}'), 8)$q$, 'PT426: save_version_too_old', 'V8b (b) v4.3.1 write (4) over a v4.4 save (5) -> PT426');
select t.throws($q$select t.up(t.save(4.1e6, '{"saveVersion": 4, "version": 5}'), 8)$q$, 'PT426: save_version_too_old', 'V8c data.version is not read: saveVersion 4 + version 5 over 5 -> PT426');
select t.throws($q$select t.up(t.save(5e6), 3)$q$, 'PT426: save_version_too_old', 'V9 stale revision AND older client -> PT426 first (guard fires before the v2.2 revision check)');
select t.throws($q$select t.up(t.save(5e6, '{"saveVersion": 5}'), 3)$q$, 'PT409: stale_revision', 'V10 stale revision, same version -> v2.2 PT409 unchanged');
select t.throws($q$select t.up(t.save(5e6, '{"saveVersion": "9"}'), 8)$q$, 'PT426: save_version_too_old', 'V11 saveVersion as string counts as missing (0)');
select t.logout();
-- exempt roles
set role postgres;
update public.kodhane_saves set data = t.save(4e6), revision = revision + 1 where user_id = :'u2';
reset role;
select t.ok((select data->>'saveVersion' is null from public.kodhane_saves where user_id = :'u2'), 'V12 manual SQL as postgres may write an older save');
update public.kodhane_saves set data = t.save(4e6, '{"saveVersion": 5}'), revision = revision + 1 where user_id = :'u2';
update public.kodhane_saves set data = t.save(4e6, '{"saveVersion": 3}'), revision = revision + 1 where user_id = :'u2';
select t.ok((select data->>'saveVersion' = '3' from public.kodhane_saves where user_id = :'u2'), 'V13 manual SQL as supabase_admin exempt', current_user);
update public.kodhane_saves set data = t.save(4e6, '{"saveVersion": 5}'), revision = revision + 1 where user_id = :'u2';
select t.as_service();
update public.kodhane_saves set data = t.save(4e6), revision = revision + 1 where user_id = '22222222-2222-4222-8222-222222222222';
select t.logout();
select t.ok((select data->>'saveVersion' is null from public.kodhane_saves where user_id = :'u2'), 'V14 service_role (service key) exempt');
update public.kodhane_saves set data = t.save(4e6, '{"saveVersion": 5}'), revision = revision + 1 where user_id = :'u2';
select t.as_service();
update public.kodhane_saves set data = t.save(4.2e6, '{"saveVersion": 4}'), revision = revision + 1 where user_id = '22222222-2222-4222-8222-222222222222';
select t.logout();
select t.ok((select data->>'saveVersion' = '4' and (data->>'totalEarned')::numeric = 4.2e6 from public.kodhane_saves where user_id = :'u2'),
  'V14b (c) service_role writes saveVersion 4 over a stored 5: exempt, accepted');
-- player RPCs (SECURITY DEFINER): reset and restore are explicit player actions
select t.login(:'u1');
select t.ok((public.kodhane_reset_save() ->> 'revision')::int = 4, 'V15 kodhane_reset_save on a saveVersion 6 save works (payload has no saveVersion)');
select t.ok((public.kodhane_restore_save((select id from public.kodhane_save_backups where user_id = auth.uid() and reason = 'reset' order by created_at desc limit 1)) ->> 'revision')::int = 5,
  'V16 kodhane_restore_save works');
select t.throws($q$select t.up(t.save(5e6))$q$, 'PT426: save_version_too_old', 'V17 after restore the stored saveVersion is the restored one (6): a v4.3.0 write is refused again');
select t.logout();
-- INSERT is never guarded (no stored save)
select t.login(:'u3');
select t.up(t.save(1e6), 1);
select t.ok((select revision = 1 from public.kodhane_saves where user_id = :'u3'), 'V18 first save (INSERT) without saveVersion accepted');
select t.logout();
-- emergency switch
select t.login(:'u2');
select t.up(t.save(4e6, '{"saveVersion": 5}'));
select t.logout();
alter table public.kodhane_saves disable trigger kodhane_saves_a_version_guard;
select t.login(:'u2'); select t.up(t.save(4.5e6)); select t.logout();
alter table public.kodhane_saves enable trigger kodhane_saves_a_version_guard;
select t.ok((select (data->>'totalEarned')::numeric = 4.5e6 from public.kodhane_saves where user_id = :'u2'), 'V19 DISABLE TRIGGER kodhane_saves_a_version_guard switches the guard off (runbook)');

-- ---------------------------------------------------------------- S: stage IDs
select t.login(:'u3');
select t.up(t.save(2e11, '{"saveVersion": 5, "version": 5, "stage": 5, "stageId": "unicorn"}'), 2);
select t.logout();
select t.ok((select best_stage = 5 and best_stage_id = 'unicorn' from public.kodhane_saves where user_id = :'u3'), 'S1 Unicorn save: best_stage 5 (legacy), best_stage_id unicorn');
select t.ok((select stage = 5 and stage_id = 'unicorn' from public.kodhane_leaderboard_v7(100) where nickname = 'Test Üç'), 'S2 v7: stage 5 + stage_id unicorn');
select t.ok((select stage = 5 from public.kodhane_leaderboard(100, 'kodhane') where nickname = 'Test Üç'), 'S3 v6 unchanged for the same row (stage 5 = Global Holding for old clients)');
select t.login(:'u3');
select t.up(t.save(2e13, '{"saveVersion": 5, "version": 5, "stage": 5, "stageId": "sirketler_grubu"}'), 3);
select t.ok((select best_stage_id = 'sirketler_grubu' from public.kodhane_saves where user_id = :'u3'), 'S4 Şirketler Grubu raises best_stage_id');
select t.up(t.save(2e13, '{"saveVersion": 5, "version": 5, "stage": 3, "stageId": "ajans", "runEarned": 2e6, "cycleEarned": 2e13, "shares": 447, "prestigeCount": 1, "cycleRounds": 1}'), 4);
select t.ok((select best_stage_id = 'sirketler_grubu' and best_stage = 5 from public.kodhane_saves where user_id = :'u3'), 'S5 lower stage later (after Yatırım Turu): best_stage_id never decreases');
select t.throws($q$update public.kodhane_saves set best_stage_id = 'mars_ofisi', revision = revision + 1 where user_id = auth.uid()$q$,
  '42501: permission denied%', 'S6 a client cannot write best_stage_id (no column grant; the trigger would overwrite it anyway)');
select t.up((select data from public.kodhane_saves where user_id = auth.uid()), 5);
select t.up(t.save(1e30, '{"saveVersion": 5, "version": 5, "stage": 8, "stageId": "mars_ofisi", "startedAt": 1}'), 6);
select t.ok((select best_stage_id = 'sirketler_grubu' from public.kodhane_saves where user_id = :'u3'), 'S7 implausible Mars claim does not raise best_stage_id');
select t.up(t.save(3e13, '{"saveVersion": 5, "version": 5, "stage": 8, "stageId": "mars_ofisi"}'), 7);
select t.ok((select best_stage_id = 'sirketler_grubu' from public.kodhane_saves where user_id = :'u3'), 'S8 unreachable stage ID (Mars at 3e13) does not raise best_stage_id');
select t.up(t.save(2e15, '{"saveVersion": 5, "version": 5, "stage": 6, "stageId": "teknoloji_devi"}'), 8);
select t.logout();
select t.ok((select best_stage = 6 and best_stage_id = 'teknoloji_devi' from public.kodhane_saves where user_id = :'u3'), 'S9 Teknoloji Devi: best_stage 6, best_stage_id teknoloji_devi');
update public.kodhane_saves set best_stage_id = 'mars_ofisi', revision = revision + 1 where user_id = :'u3';
select t.ok((select best_stage_id = 'teknoloji_devi' from public.kodhane_saves where user_id = :'u3'), 'S10a admin SQL cannot set best_stage_id either (trigger recomputes it)');
alter table public.kodhane_saves disable trigger kodhane_saves_v44_stage_id;
select t.throws($q$update public.kodhane_saves set best_stage_id = 'uzay', revision = revision + 1 where user_id = '33333333-3333-4333-8333-333333333333'$q$, '23514:%', 'S10b unknown stage ID rejected by the column check');
alter table public.kodhane_saves enable trigger kodhane_saves_v44_stage_id;
select t.ok((select count(*) = 0 from public.kodhane_leaderboard_v7(100) v
              where v.status = 'ok' and ((array[0,1,2,3,4,5,5,5,6,7,8])[public.kodhane_stage_rank(v.stage_id) + 1] is distinct from v.stage
                                         and (array[0,1,2,3,4,5,5,5,6,7,8])[public.kodhane_stage_rank(v.stage_id) + 1] < v.stage)),
  'S11 v7 stage_id never below its legacy stage (client legacyStageIndex: Unicorn / Şirketler Grubu -> Global Holding)',
  (select string_agg(coalesce(stage_id, '-') || '=' || stage, ', ') from public.kodhane_leaderboard_v7(100)));
-- v7 = v6 (+ stage_id) for anon, a listed player and a pending player
select t.ok((select count(*) = 0 from (
    (select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard(100, 'kodhane')
     except all select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard_v7(100))
    union all
    (select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard_v7(100)
     except all select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard(100, 'kodhane'))) d)
  and (select count(*) from public.kodhane_leaderboard_v7(100)) = (select count(*) from public.kodhane_leaderboard(100, 'kodhane')),
  'S12 v7 = v6 (all columns but stage_id), no login', (select count(*) from public.kodhane_leaderboard_v7(100))::text || ' rows');
select t.login(:'u3');
select t.ok((select count(*) = 0 from (
    (select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard(3, 'kodhane')
     except all select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard_v7(3))
    union all
    (select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard_v7(3)
     except all select rank, nickname, score, stage, is_me, status from public.kodhane_leaderboard(3, 'kodhane'))) d),
  'S13 v7 = v6 logged in, p_limit 3 (own row appended)');
select t.logout();
insert into public.kodhane_profiles (user_id, nickname) values ('44444444-4444-4444-8444-444444444444', 'Test Dört') on conflict do nothing;
select t.login('44444444-4444-4444-8444-444444444444');
select t.up(t.save(1e30, jsonb_build_object('saveVersion', 5, 'startedAt', floor(extract(epoch from now()) * 1000) - 60000)));
select t.ok((select count(*) = 1 and bool_and(status = 'pending' and stage is null and stage_id is null and rank is null)
             from public.kodhane_leaderboard_v7(100) where is_me),
  'S14 own pending row in v7: status pending, stage / stage_id / rank NULL (as v6)',
  (select string_agg(status || '/' || coalesce(stage_id, '-'), ',') from public.kodhane_leaderboard_v7(100) where is_me));
select t.throws($q$select public.kodhane_save_vetted_stage_id('{}')$q$, '42501:%', 'S15 players cannot call the vetted stage helper');
select t.ok(has_function_privilege('authenticated', 'public.kodhane_leaderboard_v7(integer)', 'execute')
            and has_function_privilege('anon', 'public.kodhane_leaderboard_v7(integer)', 'execute'), 'S16 anon + authenticated may call kodhane_leaderboard_v7');
select t.logout();

-- ---------------------------------------------------------------- O: float8 bounds (kodhane_score_plausible v4.4b, B)
-- t.plaus_a = the v4.4a body verbatim (created by run_v4_4b_tests.sh from the A migration), for the equality check
-- t.no_err(sql): 'ok:<result>' or 'ERR <sqlstate>'
create or replace function t.no_err(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  execute p_sql into r; return 'ok:' || coalesce(r, 'null');
exception when others then return 'ERR ' || sqlstate;
end $$;
grant execute on function t.no_err(text) to public;
select t.ok(coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') like 'Kodhane leaderboard heuristic v4.4b %',
  'O0 B installs kodhane_score_plausible v4.4b');
select t.ok(bool_and(t.no_err(format('select public.kodhane_score_plausible(%L)', x.d)) = 'ok:false'), 'O1 extreme saves -> clean false, no 22003',
  string_agg(x.n || '=' || t.no_err(format('select public.kodhane_score_plausible(%L)', x.d)), '; '))
  from (values ('X1 t 1.7976931348623157e308', '{"totalEarned": 1.7976931348623157e308, "saveVersion": 5}'::jsonb),
               ('X2 t 1e309', '{"totalEarned": 1e309, "saveVersion": 5}'),
               ('X3 s/p/cr 1e100, t 1e300', '{"totalEarned": 1e300, "cycleEarned": 1e300, "runEarned": 1, "shares": 1e100, "prestigeCount": 1e100, "cycleRounds": 1e100}'),
               ('X4 ge 1e100, ic 1', '{"totalEarned": 1e30, "shares": 1e12, "prestigeCount": 10, "cycleRounds": 1, "ipoCount": 1, "ipoSharesEarned": 1e100, "saveVersion": 5}'),
               ('X5 p/ic/ge 1e100, t 1e300', '{"totalEarned": 1e300, "shares": 1e100, "prestigeCount": 1e100, "cycleRounds": 1, "ipoCount": 1e100, "ipoSharesEarned": 1e100, "saveVersion": 5}'),
               ('X7 t 1e308', '{"totalEarned": 1e308, "saveVersion": 5}'),
               ('X8 t 1.7976931e308', '{"totalEarned": 1.7976931e308, "saveVersion": 5}'),
               ('X9 ge 1e90', '{"totalEarned": 1e30, "shares": 1e12, "prestigeCount": 10, "cycleRounds": 1, "ipoCount": 1, "ipoSharesEarned": 1e90, "saveVersion": 5}'),
               ('X10 ge 1e98', '{"totalEarned": 1e30, "shares": 1e12, "prestigeCount": 10, "cycleRounds": 1, "ipoCount": 1, "ipoSharesEarned": 1e98, "saveVersion": 5}'),
               ('X11 ge 1e51, ic 1', '{"totalEarned": 1e30, "shares": 1e12, "prestigeCount": 10, "cycleRounds": 1, "ipoCount": 1, "ipoSharesEarned": 1e51, "saveVersion": 5}'),
               ('X12 t 1e300 + 1', jsonb_build_object('totalEarned', 1e300 + 1, 'saveVersion', 5)),
               ('X13 runEarned 1e301', '{"totalEarned": 1e6, "runEarned": 1e301, "saveVersion": 5}'),
               ('X14 cycleEarned -1e301', '{"totalEarned": 1e6, "cycleEarned": -1e301, "saveVersion": 5}'),
               ('X15 shares -1e400', '{"totalEarned": 1e6, "shares": -1e400, "saveVersion": 5}'),
               ('X16 counters 1e50 + 1', jsonb_build_object('totalEarned', 1e30, 'shares', 1e50 + 1, 'prestigeCount', 10, 'cycleRounds', 1, 'saveVersion', 5)),
               ('X17 p 1e50, ic 1e50, t 1e300 (share cap, no product)', '{"totalEarned": 1e300, "cycleEarned": 1e300, "shares": 1e50, "prestigeCount": 1e50, "cycleRounds": 1e50, "ipoCount": 1e50, "ipoSharesEarned": 1e50, "saveVersion": 5}'),
               ('X18 cr 1e50 x prev 1e300 (share check, no product)', '{"totalEarned": 1e300, "cycleEarned": 1e300, "runEarned": 1, "shares": 1e50, "prestigeCount": 1e50, "cycleRounds": 1e50, "saveVersion": 4}'),
               ('X19 money 1e400 (not read)', '{"totalEarned": 1e400, "money": 1e400, "saveVersion": 5}')) x(n, d);
select t.ok(t.no_err($q$select public.kodhane_score_plausible('{"totalEarned": 1e300, "saveVersion": 5}')$q$) like 'ok:%'
            and t.no_err($q$select public.kodhane_score_plausible('{"totalEarned": 1e30, "shares": 1e50, "prestigeCount": 1e50, "cycleRounds": 1e50, "ipoCount": 1e50, "ipoSharesEarned": 1e50, "saveVersion": 5}')$q$) like 'ok:%',
  'O2 exactly on the bounds (totalEarned 1e300, counters 1e50): boolean, no error');
-- O3: same result as v4.4a on a grid of saves inside the bounds (38400 saves; v4.4a never overflows there)
create temp table o_grid as
  select jsonb_build_object('saveVersion', v, 'version', v, 'startedAt', extract(epoch from timestamptz '2026-09-27 00:00:00+00') * 1000,
           'lastSaved', floor(extract(epoch from now()) * 1000), 'totalEarned', t, 'runEarned', case when r = 1 then t else floor(t / 1000) end,
           'cycleEarned', t, 'shares', s, 'prestigeCount', p, 'cycleRounds', least(p, cr), 'ipoCount', ic, 'ipoSharesEarned', ge) as d, t
    from unnest(array[0, 1, 1e3, 1e6, 1e9, 1e12, 9e15, 9007199254740992, 9007199254740993, 1e19, 1e21, 9679236323441331000000, 1e30, 1e50, 1e100, 1e300]::numeric[]) t,
         unnest(array[0, 1, 10, 1e4, 1e6, 1e7, 1e9, 1e11, 1e12, 1e13]::numeric[]) s, unnest(array[0, 1, 9, 100, 1e4]::numeric[]) p,
         unnest(array[1, 1e9]::numeric[]) cr, unnest(array[0, 1]::numeric[]) ic, unnest(array[0, 1, 40]::numeric[]) ge,
         unnest(array[4, 5]) v, unnest(array[1, 2]) r;
grant select on o_grid to public;
select t.ok(count(*) = 38400 and count(*) filter (where public.kodhane_score_plausible(d) is distinct from t.plaus_a(d)) = 0,
  'O3 v4.4b = v4.4a on 38400 saves inside the bounds (totalEarned 0..1e300 incl. 9e15, 2^53+1, 1e21, 9.68e21, 1e30)',
  count(*) || ' saves, ' || count(*) filter (where public.kodhane_score_plausible(d) is distinct from t.plaus_a(d)) || ' differ, '
  || count(*) filter (where public.kodhane_score_plausible(d)) || ' plausible') from o_grid;
select t.ok(bool_and(n > 0), 'O4 9e15 .. 1e30 still pass: every value has plausible saves in the grid (v4.3 and v4.4 format)',
  string_agg(t || ':' || n, ' ' order by t)) from (
  select g.t, (g.d ->> 'saveVersion')::int as v, count(*) filter (where public.kodhane_score_plausible(g.d)) as n from o_grid g
   where g.t between 9e15 and 1e30 group by 1, 2) x;
-- O5-O9: write path and leaderboards with an extreme save
insert into auth.users (id) values ('55555555-5555-4555-8555-555555555555') on conflict do nothing;
insert into public.kodhane_profiles (user_id, nickname) values ('55555555-5555-4555-8555-555555555555', 'Test Beş') on conflict do nothing;
create temp table o5 as select d from o_grid where t = 1e21 and (d ->> 'saveVersion')::int = 5 and public.kodhane_score_plausible(d)
  order by (d ->> 'shares')::numeric, (d ->> 'prestigeCount')::numeric limit 1;
grant select on o5 to public;
select t.login('55555555-5555-4555-8555-555555555555');
select t.up((select d from o5), 1);
select t.logout();
create temp table o_before as select best_score, revision from public.kodhane_saves where user_id = '55555555-5555-4555-8555-555555555555';
select t.ok((select best_score = 1e21 from o_before), 'O5 setup: plausible 1e21 save written, best_score 1e21', (select best_score::text from o_before));
select t.login('55555555-5555-4555-8555-555555555555');
select t.ok(t.no_err($q$select t.up('{"totalEarned": 1e30, "shares": 1e12, "prestigeCount": 10, "cycleRounds": 1, "ipoCount": 1, "ipoSharesEarned": 1e100, "saveVersion": 5}', 2)$q$) like 'ok:%',
  'O6 player writes the X4 save (ipoSharesEarned 1e100): accepted without 22003 (was a 22003 refusal before v4.4b)');
select t.logout();
select t.ok((select s.best_score = b.best_score and s.revision = 2 and (s.data ->> 'ipoSharesEarned')::numeric = 1e100
               from public.kodhane_saves s, o_before b where s.user_id = '55555555-5555-4555-8555-555555555555'),
  'O7 implausible: best_score stays 1e21 (the extreme save never enters the leaderboard score)');
set session_replication_role = replica;   -- admin write that bypasses every trigger
update public.kodhane_saves set data = '{"totalEarned": 1.7976931348623157e308, "runEarned": 1e300, "cycleEarned": 1e300, "shares": 1e100, "prestigeCount": 1e100, "cycleRounds": 1e100, "ipoCount": 1e100, "ipoSharesEarned": 1e100, "saveVersion": 5}'
 where user_id = '55555555-5555-4555-8555-555555555555';
update public.kodhane_saves set data = '{"totalEarned": 1e30, "shares": 1e12, "prestigeCount": 10, "cycleRounds": 1, "ipoCount": 1, "ipoSharesEarned": 1e100, "saveVersion": 5}'
 where user_id = '44444444-4444-4444-8444-444444444444';
set session_replication_role = origin;
select t.ok(t.no_err($q$select count(*)::text from public.kodhane_leaderboard(100, 'kodhane')$q$) like 'ok:%'
            and t.no_err($q$select count(*)::text from public.kodhane_leaderboard_v7(100)$q$) like 'ok:%',
  'O8 extreme rows written with session_replication_role = replica: kodhane_leaderboard and _v7 answer (no 22003)',
  t.no_err($q$select count(*)::text from public.kodhane_leaderboard(100, 'kodhane')$q$) || ' / ' || t.no_err($q$select count(*)::text from public.kodhane_leaderboard_v7(100)$q$));
select t.ok((select score = 1e21 and status = 'ok' from public.kodhane_leaderboard(100, 'kodhane') where nickname = 'Test Beş')
            and (select score = 1e21 from public.kodhane_leaderboard_v7(100) where nickname = 'Test Beş')
            and not exists (select 1 from public.kodhane_leaderboard(100, 'kodhane') where nickname = 'Test Dört' and status = 'ok'),
  'O9 the extreme current save is not counted: Test Beş listed with its best_score 1e21, Test Dört (best_score 0) not listed',
  (select string_agg(nickname || '=' || coalesce(score::text, status), ', ') from public.kodhane_leaderboard(100, 'kodhane') where nickname in ('Test Beş', 'Test Dört')));
select t.login('55555555-5555-4555-8555-555555555555');
select t.ok(t.no_err($q$select count(*)::text from public.kodhane_leaderboard_v7(100) where is_me$q$) = 'ok:1', 'O10 the player with the extreme row can read v7 (own row)');
select t.logout();
delete from public.kodhane_saves where user_id = '55555555-5555-4555-8555-555555555555';
delete from public.kodhane_profiles where user_id = '55555555-5555-4555-8555-555555555555';
