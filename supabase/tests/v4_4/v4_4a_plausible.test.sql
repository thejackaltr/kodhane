-- Package A tests (kodhane_score_plausible v4.4a). LOCAL THROWAWAY DB ONLY (run_v4_4a_tests.sh).
-- Needs: t.ok / t.login / t.logout (fixtures/helpers.sql functions), t.plaus_v43 (= the live v4.3 rule, renamed),
-- t.sim (client sim snapshots), t.honest (kodhane-cloud/honest_sims.json), t.fik (anonymous copy of the compensated save),
-- t.live_before (plausible() of every copied live save before A). psql vars: fik (uuid of the anonymous copy).
\set ON_ERROR_STOP on
create or replace function t.pl(d jsonb, n timestamptz default now()) returns boolean language sql stable as
  $$ select public.kodhane_score_plausible(d, n) $$;
create or replace function t.v43_safe(d jsonb, n timestamptz) returns text language plpgsql stable as
  $$ begin return t.plaus_v43(d, n)::text; exception when others then return 'error ' || sqlstate; end $$;
create or replace function t.ms_at(ms float8) returns timestamptz language sql immutable as $$ select to_timestamp(ms / 1000) $$;

-- ---------------------------------------------------------------- A1-A5: honest client saves
select t.ok(count(*) filter (where not t.pl(j->'data', t.ms_at((j->>'now_ms')::float8))) = 0 and count(*) > 0,
  'A1 v4.3.0 client saves (sim, no saveVersion) all plausible', count(*) || ' snapshots, ' || count(distinct file) || ' runs')
  from t.sim where j->>'game' = 'v430live';
select t.ok(count(*) filter (where not t.pl(j->'data', t.ms_at((j->>'now_ms')::float8))) = 0 and count(*) > 0,
  'A2 v4.3.1 client saves (sim, saveVersion 4) all plausible', count(*) || ' snapshots, ' || count(distinct file) || ' runs')
  from t.sim where j->>'game' = 'v431';
select t.ok(count(*) filter (where not t.pl(j->'data', t.ms_at((j->>'now_ms')::float8))) = 0 and count(*) > 0
            and bool_and(not (j->'data' ? 'saveVersion')),
  'A3a saves without saveVersion (v4.1.1 client sim) all plausible', count(*) || ' snapshots, ' || count(distinct file) || ' runs')
  from t.sim where j->>'game' = 'v411';
select t.ok(count(*) filter (where not t.pl(h.save, t.ms_at(h.now_ms))) = 0 and count(*) = 10,
  'A3b kodhane-cloud honest_sims.json (v4 era, no saveVersion) all plausible', count(*) || ' saves') from t.honest h;
select t.ok(count(*) filter (where not t.pl(j->'data', t.ms_at((j->>'now_ms')::float8))) = 0 and count(*) > 0,
  'A4 v4.4.0 client saves (all sim profiles x Halka Arz modes) all plausible',
  count(*) || ' snapshots, ' || count(distinct file) || ' runs; old v4.3 rule rejects '
  || count(*) filter (where not t.plaus_v43(j->'data', t.ms_at((j->>'now_ms')::float8))))
  from t.sim where j->>'game' = 'v440';
select t.ok(count(*) filter (where t.plaus_v43(j->'data', t.ms_at((j->>'now_ms')::float8))
                               and not t.pl(j->'data', t.ms_at((j->>'now_ms')::float8))) = 0,
  'A5 nothing the v4.3 rule accepted is rejected now (all sim snapshots)', count(*) || ' snapshots')
  from t.sim;
-- v4.3.0 tab that loaded a v4.4 save writes version 5 without saveVersion / stage IDs / new employees
select t.ok(count(*) filter (where not t.pl(x.d, t.ms_at((j->>'now_ms')::float8))) = 0,
  'A6 v4.4 save re-written by a v4.3.0 tab (version 5 kept, *Id + veri/cip dropped) plausible', count(*) || ' snapshots')
  from t.sim, lateral (select (((j->'data') - 'saveVersion' - 'stageId' - 'stageBestId' - 'cycleStageId')
                              || jsonb_build_object('gens', ((j->'data'->'gens') - 'veri') - 'cip')) as d) x
  where j->>'game' = 'v440';

-- ---------------------------------------------------------------- F: compensated save (anonymous copy, 1100 shares added by hand)
select t.ok(not t.plaus_v43((select data from t.fik)) and t.pl((select data from t.fik)),
  'F1 compensated save: v4.3 rule false (frozen), v4.4a true',
  (select format('shares %s, prestigeCount %s, cycleRounds %s, ipoCount %s, totalEarned %s', data->>'shares', data->>'prestigeCount',
                 data->>'cycleRounds', data->>'ipoCount', data->>'totalEarned') from t.fik));
select t.login(:'fik');
update public.kodhane_saves set revision = revision + 1, updated_at = now(), save_version = 4,
  data = data || jsonb_build_object('totalEarned', (data->>'totalEarned')::numeric + 5e11, 'runEarned', (data->>'runEarned')::numeric + 5e11,
                                    'cycleEarned', (data->>'cycleEarned')::numeric + 5e11, 'lastSaved', floor(extract(epoch from now()) * 1000))
  where user_id = :'fik';
select t.logout();
select t.ok((select best_score > (select best_score from t.fik) and best_score = (data->>'totalEarned')::numeric
               and revision = (select revision from t.fik) + 1 from public.kodhane_saves where user_id = :'fik'),
  'F2 next write (revision +1, strict) raises best_score past the frozen value',
  (select format('%s -> %s', (select best_score from t.fik), best_score) from public.kodhane_saves where user_id = :'fik'));
select t.login(:'fik');
update public.kodhane_saves set revision = revision + 1, updated_at = now(),
  data = data || jsonb_build_object('totalEarned', 1.2e15, 'runEarned', 1.0e15 + 1e12, 'cycleEarned', 1.0e15 + 1e12 + 1.16e10,
                                    'stage', 6, 'stageBest', 6, 'cycleStage', 6, 'lastSaved', floor(extract(epoch from now()) * 1000))
  where user_id = :'fik';
select t.logout();
select t.ok((select best_stage = 6 and best_score = 1.2e15 from public.kodhane_saves where user_id = :'fik'),
  'F3 stage-up write (Teknoloji Devi at 1.2e15) raises best_stage 5 -> 6',
  (select format('best_stage %s, best_score %s', best_stage, best_score) from public.kodhane_saves where user_id = :'fik'));
select t.ok((select score = 1.2e15 and stage = 6 and status = 'ok' from public.kodhane_leaderboard(100, 'kodhane') l
              join public.kodhane_profiles p on p.nickname = l.nickname where p.user_id = :'fik'),
  'F4 leaderboard shows the moved score and stage');
select t.ok(not t.pl((select data from t.fik) || jsonb_build_object('shares', 1320)),
  'F5 same save with shares above the new bound (1320 > sqrt(4 x 4.34e13 / 1e8) + 1 = 1318.9) still false');

-- ---------------------------------------------------------------- C: cheat values (all must be false)
create temp table cheats (name text, d jsonb, n timestamptz);
-- C1 legacy e2e cheats (kodhane-cloud/e2e_leaderboard_teserix.py) on the same honest saves
insert into cheats select 'legacy ' || m.name || ' (aktif-2gun-smart)', m.d, t.ms_at(h.now_ms) from t.honest h, lateral (values
  ('x100', h.save || jsonb_build_object('totalEarned', (h.save->>'totalEarned')::numeric * 100, 'runEarned', (h.save->>'runEarned')::numeric * 100)),
  ('shares x10', h.save || jsonb_build_object('shares', (h.save->>'shares')::numeric * 10)),
  ('x3 without prestige history', h.save || jsonb_build_object('totalEarned', (h.save->>'totalEarned')::numeric * 3, 'runEarned', (h.save->>'totalEarned')::numeric * 3, 'shares', 0, 'prestigeCount', 0)),
  ('prestigeCount > shares', h.save || jsonb_build_object('prestigeCount', (h.save->>'shares')::numeric + 1))) m(name, d)
  where h.name = 'aktif-2gun-smart';
insert into cheats select 'legacy IPO ' || m.name || ' (ipo-smart-7gun)', m.d, t.ms_at(h.now_ms) from t.honest h, lateral (values
  ('Borsa Payı 1e6', h.save || '{"ipoSharesEarned": 1000000}'),
  ('fewer Borsa Payı than IPOs', h.save || jsonb_build_object('ipoSharesEarned', (h.save->>'ipoCount')::numeric - 1)),
  ('cycle earnings > total', h.save || jsonb_build_object('cycleEarned', (h.save->>'totalEarned')::numeric * 2)),
  ('run earnings > cycle', h.save || jsonb_build_object('runEarned', (h.save->>'cycleEarned')::numeric * 2, 'totalEarned', (h.save->>'totalEarned')::numeric + (h.save->>'cycleEarned')::numeric * 2)),
  ('cycleRounds > prestigeCount', h.save || jsonb_build_object('cycleRounds', (h.save->>'prestigeCount')::numeric + 1)),
  ('cycleRounds > shares', h.save || jsonb_build_object('cycleRounds', (h.save->>'shares')::numeric + 1, 'prestigeCount', greatest((h.save->>'prestigeCount')::numeric, (h.save->>'shares')::numeric + 1))),
  ('earlier cycles without any IPO', h.save || '{"ipoCount": 0, "ipoSharesEarned": 0}'),
  ('x100', h.save || jsonb_build_object('totalEarned', (h.save->>'totalEarned')::numeric * 100, 'cycleEarned', (h.save->>'cycleEarned')::numeric * 100, 'runEarned', (h.save->>'runEarned')::numeric * 100))) m(name, d)
  where h.name = 'ipo-smart-7gun';
insert into cheats select 'legacy IPO 12 x ipoCount + 50 pays (ipo-idle-14gun)', h.save || jsonb_build_object('ipoSharesEarned', (h.save->>'ipoCount')::numeric * 12 + 50), t.ms_at(h.now_ms)
  from t.honest h where h.name = 'ipo-idle-14gun';
insert into cheats select 'legacy ' || m.name || ' (aktif-1gun-asap)', m.d, t.ms_at(h.now_ms) from t.honest h, lateral (values
  ('honest x1e6', h.save || jsonb_build_object('totalEarned', (h.save->>'totalEarned')::numeric * 1e6, 'runEarned', (h.save->>'runEarned')::numeric * 1e6)),
  ('runEarned > totalEarned', h.save || jsonb_build_object('runEarned', (h.save->>'totalEarned')::numeric * 2)),
  ('prestigeCount = shares + 5', h.save || jsonb_build_object('prestigeCount', (h.save->>'shares')::numeric + 5)),
  ('shares x1000', h.save || jsonb_build_object('shares', (h.save->>'shares')::numeric * 1000)),
  ('previous-run earnings +1e30', h.save || jsonb_build_object('totalEarned', (h.save->>'runEarned')::numeric + 1e30))) m(name, d)
  where h.name = 'aktif-1gun-asap';
insert into cheats values
  ('legacy fresh total=run=1.234e30', '{"version": 2, "totalEarned": 1.234e30, "runEarned": 1.234e30, "stage": 5}', now()),
  ('legacy fresh total=run=1.5e300', '{"version": 2, "totalEarned": 1.5e300, "runEarned": 1.5e300, "stage": 5}', now()),
  ('legacy fresh 1e17 after 1 minute', jsonb_build_object('version', 2, 'totalEarned', 1e17, 'runEarned', 1e17, 'shares', 0, 'prestigeCount', 0,
     'startedAt', floor(extract(epoch from now()) * 1000) - 60000, 'lastSaved', floor(extract(epoch from now()) * 1000), 'stage', 5), now()),
  ('v2.2 u2: 1e30 on a brand-new save', jsonb_build_object('version', 4, 'startedAt', floor(extract(epoch from now()) * 1000) - 60000,
     'lastSaved', floor(extract(epoch from now()) * 1000), 'totalEarned', 1e30, 'runEarned', 1e30, 'money', 5), now()),
  ('totalEarned 1e309 (above float8)', '{"totalEarned": 1e309}', now()),
  ('totalEarned negative', '{"totalEarned": -1}', now()),
  ('totalEarned string', '{"totalEarned": "1e9"}', now()),
  ('not an object', '[1, 2]', now());
-- C2 v4.4a: last snapshot of a v4.3.0 / v4.4 run with Halka Arz (tutkulu smart), and one of v4.4 without
create temp table base as
  select distinct on (j->>'game') j->>'game' as game, j->'data' as d, t.ms_at((j->>'now_ms')::float8) as n, t.diag(j->'data', t.ms_at((j->>'now_ms')::float8)) as v
    from t.sim where file in ('v430live.tutkulu.smart.44', 'v440.tutkulu.smart.44') and j->>'kind' = 'end' order by j->>'game', n desc;
insert into cheats select b.game || ' IPO: ' || m.name, m.d, b.n from base b, lateral (values
  ('shares 1% above the share cap', b.d || jsonb_build_object('shares', ceil((b.v->>'share_cap')::numeric * 1.01) + 1)),
  ('shares x1000', b.d || jsonb_build_object('shares', (b.d->>'shares')::numeric * 1000 + 1000)),
  ('x100 all earnings', b.d || jsonb_build_object('totalEarned', (b.d->>'totalEarned')::numeric * 100, 'cycleEarned', (b.d->>'cycleEarned')::numeric * 100, 'runEarned', (b.d->>'runEarned')::numeric * 100)),
  ('unknown employee', b.d || jsonb_build_object('gens', (b.d->'gens') || '{"robot": 1}')),
  ('negative employee count', b.d || jsonb_build_object('gens', (b.d->'gens') || '{"stajyer": -1}')),
  ('employee count as string', b.d || jsonb_build_object('gens', (b.d->'gens') || '{"junior": "5"}')),
  ('shares as string', b.d || '{"shares": "1e9"}'),
  ('ipoCount as string', b.d || '{"ipoCount": "3"}')) m(name, d);
insert into cheats select s.game || ' first Halka Arz: Borsa Payı 12 x ipoCount + 50 (small older earnings)',
  s.d || jsonb_build_object('ipoSharesEarned', (s.d->>'ipoCount')::numeric * 12 + 50), s.n
  from (select distinct on (j->>'game') j->>'game' as game, j->'data' as d, t.ms_at((j->>'now_ms')::float8) as n from t.sim
         where file in ('v430live.tutkulu.smart.44', 'v440.tutkulu.smart.44') and j->>'kind' = 'post_ipo' order by j->>'game', n) s;
insert into cheats select 'v430live (format 4): ' || m.name, m.d, b.n from base b, lateral (values
  ('Veri Merkezi owned', b.d || jsonb_build_object('gens', (b.d->'gens') || '{"veri": 5}')),
  ('Çip Fabrikası owned', b.d || jsonb_build_object('gens', (b.d->'gens') || '{"cip": 1}')),
  ('stage IDs (unicorn)', b.d || '{"stageId": "unicorn", "stageBestId": "unicorn"}'),
  ('v4.4 accelerated share cap (5x) claimed on format 4', b.d || jsonb_build_object('shares', ceil((b.v->>'share_cap')::numeric * 2)))) m(name, d)
  where b.game = 'v430live';
insert into cheats select 'v440: ' || m.name, m.d, b.n from base b, lateral (values
  ('unknown stage ID', b.d || '{"stageBestId": "uzay_ussu"}'),
  ('stage ID as number', b.d || '{"stageId": 5}')) m(name, d)
  where b.game = 'v440';
insert into cheats select 'v440 early save: ' || m.name, m.d, t.ms_at((s.j->>'now_ms')::float8) from
  (select j from t.sim where file = 'v440.gunluk.smart.44' and (j->'data'->>'totalEarned')::float8 between 1e9 and 5e10 order by n limit 1) s,
  lateral (values
  ('stageBestId mars_ofisi below 1e23', (s.j->'data') || '{"stageBestId": "mars_ofisi"}'),
  ('stageId unicorn below 1e11', (s.j->'data') || '{"stageId": "unicorn"}'),
  ('Ar-Ge Kampüsü below 1e13', (s.j->'data') || jsonb_build_object('gens', (s.j->'data'->'gens') || '{"arge": 1}')),
  ('Veri Merkezi below 1e11', (s.j->'data') || jsonb_build_object('gens', (s.j->'data'->'gens') || '{"veri": 1}'))) m(name, d);
select t.ok(not coalesce(t.pl(c.d, c.n), false), 'C ' || c.name, 'v4.3 rule: ' || coalesce(t.v43_safe(c.d, c.n), 'null'))
  from cheats c order by c.name;
select t.ok((select count(*) from cheats) >= 40, 'C count', (select count(*) from cheats)::text);
select t.ok(t.pl(h.save || jsonb_build_object('ipoSharesEarned', (h.save->>'ipoCount')::numeric * 12), t.ms_at(h.now_ms)),
  'C-ok 12 pays per IPO (Mars every cycle) still plausible (ipo-idle-14gun)') from t.honest h where h.name = 'ipo-idle-14gun';
select t.ok(t.pl(b.d || jsonb_build_object('shares', floor((b.v->>'share_cap')::numeric)), b.n),
  'C-ok ' || b.game || ' IPO save exactly at the share cap is plausible (bound is inclusive)') from base b;

-- ---------------------------------------------------------------- L: dry-run of the copied live saves
select t.ok(count(*) filter (where lb.ok and not t.pl(s.data)) = 0 and count(*) filter (where not t.pl(s.data)) = 0,
  'L1 live copy: no real player flagged (before A -> after A)',
  format('%s saves; v4.3 rule: %s plausible / %s not; v4.4a: %s / %s', count(*), count(*) filter (where lb.ok), count(*) filter (where not lb.ok),
         count(*) filter (where t.pl(s.data)), count(*) filter (where not t.pl(s.data))))
  from public.kodhane_saves s join t.live_before lb using (user_id) where s.user_id <> :'fik';
