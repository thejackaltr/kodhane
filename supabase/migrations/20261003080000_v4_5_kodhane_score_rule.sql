-- Kodhane v4.5 skor kuralı (migration 20261003080000): kodhane_score_plausible v4.5 for the v4.5 game (price curve,
-- employee tiers, Borsa dalı, 1e21 stage). SEPARATE install step with its own approval, AFTER package B
-- (20260929204000) and BEFORE the v4.5 client push: B -> this migration (verified live) -> v4.5 push.
-- Runbook: docs/kodhane-v4.5-score-rule-runbook.md. Install: supabase/ops/kodhane_score_rule_install.sh.
--
-- Changes against v4.4b (everything else is the v4.4b body, byte for byte):
--   1. stage_ids_ok knows the new stage 'asama_1e21' (at 1e21, between yapay_zeka_lab 1e19 and mars_ofisi 1e23).
--   2. time x max income: the employee tier multiplier 32 (5 old tiers x2, counts 1 ... 100) becomes tier_mult of the
--      config: 32 x 1.25^14 = 727.6 (14 new tiers at 150 ... 10000, x1.25 each; generous: all tiers assumed reached).
--   3. units per employee: v4.4b floor(ln(t x 0.15 / b + 1) / ln 1.15) (0.14 / 1.14 with a Halka Arz) assumes one
--      growth for every unit; v4.5 prices follow a piecewise curve (cheaper after 300 units), so the rule inverts the
--      cumulative cost of the config curve segment by segment. With a Halka Arz the growth above 1 is cut by
--      ik_factor (İK Anlaşması 0.14 / 0.15) x borsa_cut (Borsa 1, x0.8), as generous as B (assumed with ic >= 0.5).
--      After the last segment start the last growth goes on (also past 10000). The count is never below the v4.4b
--      count (greatest of both): with any curve (also F3, costlier at 100-300) the rule stays at least as generous as B.
--   4. the parameters come from ONE active row of kodhane_rule.score_curve (read through the SECURITY DEFINER
--      helper kodhane_rule.active_score_curve(); kodhane_score_plausible stays LANGUAGE sql, SECURITY INVOKER).
--      Rows: 'v45_f2' (GD curve, ACTIVE) and 'v45_f3' (H20 curve, inactive). No active row -> the helper falls back
--      to the built-in v45_f2 values (never "everyone implausible").
--   5. B's stage catalogue learns asama_1e21: kodhane_stage_rank / kodhane_stage_at (between yapay_zeka_lab and
--      mars_ofisi) and the CHECK kodhane_saves_best_stage_id_known; otherwise the leaderboard lists such a player
--      with yapay_zeka_lab. Saves already at asama_1e21 with a lower best_stage_id are backfilled (expected 0 on
--      live); every change of best_stage_id to asama_1e21 is logged with the value before (kodhane_rule.stage_1e21_log)
--      so the rollback restores it exactly.
--   6. SET jit = off on kodhane_score_plausible (proconfig search_path="" + jit=off). Measured 2026-10-04 on a PG 17
--      build with a working LLVM JIT: ~7 s per call with jit = on,
--      ~10 ms with jit = off. Live and the .136 image report jit = on but pg_jit_available() = f (no effect today);
--      the setting keeps the rule fast if JIT ever becomes available. Callers (vetted score / stage, leaderboard,
--      loss report) need nothing: the function's own SET applies to its inner query wherever it is called from.
--      The rollback's v4.4b definition has no jit setting (create or replace drops it).
--   Open (not changed here): stage bonus stage_mult stays 2.0 (with the new stage 2.1 could be argued; the simulation
--   used 2.0).
-- Rollback: supabase/rollback/20261003080000_v4_5_kodhane_score_rule.rollback.sql (back to the v4.4b definition).
-- The body between the markers <v4_5_body> ... </v4_5_body> is a plain query on d / p_now: the preflight runs it read
-- only on the real saves, with the line marked <score_curve_source> replaced by the literal curve.
begin;
do $pre$
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('auth.users') is null then
    raise exception 'v4.5 score rule: wrong target (public.kodhane_saves / auth.users missing in database %)', current_database();
  end if;
  if to_regclass('public.fenomen_saves') is not null then
    raise exception 'v4.5 score rule: wrong target (public.fenomen_saves exists: this is a Fenomen database)';
  end if;
  if to_regprocedure('public.kodhane_score_plausible(jsonb,timestamptz)') is null
     or (coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') not like 'Kodhane leaderboard heuristic v4.4b %'
         and coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') not like 'Kodhane leaderboard heuristic v4.5 %') then
    raise exception 'v4.5 score rule: package B (20260929204000, kodhane_score_plausible v4.4b) is not installed here; install B first';
  end if;
end $pre$;

create schema if not exists kodhane_rule;
alter schema kodhane_rule owner to postgres;
revoke all on schema kodhane_rule from public, anon, authenticated, service_role;
grant usage on schema kodhane_rule to service_role;   -- = who may execute kodhane_score_plausible (postgres, service_role)

-- growth = [[first unit, price growth], ...]: 1 ... 16 pairs, first unit 0, integer and strictly increasing, 1 < growth <= 2
create or replace function kodhane_rule.score_curve_growth_ok(p jsonb) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select coalesce(jsonb_typeof(p) = 'array' and jsonb_array_length(p) between 1 and 16
    and (select bool_and(jsonb_typeof(e.x) = 'array' and jsonb_array_length(e.x) = 2
                         and jsonb_typeof(e.x -> 0) = 'number' and jsonb_typeof(e.x -> 1) = 'number'
                         and (e.x ->> 0)::numeric = trunc((e.x ->> 0)::numeric) and (e.x ->> 0)::numeric between 0 and 1e6
                         and (e.x ->> 1)::numeric > 1 and (e.x ->> 1)::numeric <= 2
                         and case when e.i = 1 then (e.x ->> 0)::numeric = 0
                                  else (e.x ->> 0)::numeric > (p -> (e.i::int - 2) ->> 0)::numeric end)
           from jsonb_array_elements(p) with ordinality e(x, i)), false)
$$;

create table if not exists kodhane_rule.score_curve (
  id text primary key constraint score_curve_id_check check (id ~ '^[a-z0-9_]{1,40}$'),
  active boolean not null default false,
  growth jsonb not null constraint score_curve_growth_check check (kodhane_rule.score_curve_growth_ok(growth)),
  tier_mult double precision not null constraint score_curve_tier_mult_check check (tier_mult >= 32 and tier_mult <= 1e6),
  ik_factor double precision not null constraint score_curve_ik_factor_check check (ik_factor > 0 and ik_factor <= 1),
  borsa_cut double precision not null constraint score_curve_borsa_cut_check check (borsa_cut > 0 and borsa_cut <= 1),
  note text constraint score_curve_note_check check (note is null or length(note) <= 500),
  created_at timestamptz not null default now()
);
alter table kodhane_rule.score_curve owner to postgres;
create unique index if not exists score_curve_one_active on kodhane_rule.score_curve ((true)) where active;
alter table kodhane_rule.score_curve enable row level security;
revoke all on table kodhane_rule.score_curve from public, anon, authenticated, service_role;
comment on table kodhane_rule.score_curve is
  'Kodhane v4.5 score rule parameters (migration 20261003080000): price curve growth [[first unit, growth], ...], tier_mult (all employee tiers), ik_factor (İK Anlaşması), borsa_cut (Borsa 1). At most one active row (score_curve_one_active); kodhane_score_plausible reads it through kodhane_rule.active_score_curve(). Change only with the runbook (separate approval).';

insert into kodhane_rule.score_curve (id, active, growth, tier_mult, ik_factor, borsa_cut, note) values
  ('v45_f2', true,  '[[0, 1.15], [300, 1.10], [500, 1.05], [1000, 1.025], [3000, 1.0125]]', 32 * power(1.25::float8, 14), 0.14::float8 / 0.15, 0.8,
   'F2 (sim r3, kodhane-v4.5-ozet-r3.md): GD curve, 14 new tiers x1.25 (150 ... 10000), Borsa 1 growth cut 0.8, İK 0.14/0.15'),
  ('v45_f3', false, '[[0, 1.15], [100, 1.20], [300, 1.10], [500, 1.05], [1000, 1.025], [3000, 1.0125]]', 32 * power(1.25::float8, 14), 0.14::float8 / 0.15, 0.8,
   'F3 (comparison, results/f3_choice.json H20x125): H20 curve, tiers x1.25; activate only if the game ships F3')
on conflict (id) do nothing;

-- the one active row; none -> the built-in v45_f2 values (= the row above), so a missing row never hides everyone
create or replace function kodhane_rule.active_score_curve()
returns table (growth jsonb, tier_mult double precision, ik_factor double precision, borsa_cut double precision)
language sql stable parallel safe security definer set search_path = '' as $$
  select c.growth, c.tier_mult, c.ik_factor, c.borsa_cut from kodhane_rule.score_curve c where c.active
  union all
  select '[[0, 1.15], [300, 1.10], [500, 1.05], [1000, 1.025], [3000, 1.0125]]'::jsonb, 32 * power(1.25::float8, 14), 0.14::float8 / 0.15, 0.8::float8
   where not exists (select 1 from kodhane_rule.score_curve c where c.active)
  limit 1
$$;
alter function kodhane_rule.active_score_curve() owner to postgres;
alter function kodhane_rule.score_curve_growth_ok(jsonb) owner to postgres;
revoke all on function kodhane_rule.active_score_curve() from public, anon, authenticated, service_role;
revoke all on function kodhane_rule.score_curve_growth_ok(jsonb) from public, anon, authenticated, service_role;
grant execute on function kodhane_rule.active_score_curve() to service_role;

-- ---------------------------------------------------------------- kodhane_score_plausible v4.5
create or replace function public.kodhane_score_plausible(d jsonb, p_now timestamptz default now())
 returns boolean
 language sql
 stable parallel safe
 set search_path to ''
 set jit to off
as $function$
-- <v4_5_body>
select coalesce((
  select case
    -- 0) types: every field the rule reads is a JSON number (or absent/null); totalEarned is required
    when not v.types_ok or not v.t_ok or not v.run_ok or not v.cyc_ok then false
    -- v4.4b: float8 bounds. Counters above 1e50 (clamped to 1e51 below) are no real save: clean false, never 22003
    when greatest(v.s, v.p, v.cr, v.ic, v.ge) > 1e50 then false
    when v.run < 0 or v.cyc < 0 or v.s < 0 or v.p < 0 or v.cr < 0 or v.ic < 0 or v.ge < 0 then false
    -- v4.4a: employee types / stage IDs. v4.3.x clients (save format <= 4) drop unknown employees and never write *Id
    -- fields, so a format <= 4 save carrying Veri Merkezi / Çip Fabrikası / stage IDs is not from a real client.
    when not v.gens_ok then false
    when not v.stage_ids_ok then false
    -- A) structure (unchanged from v4.3 unless marked)
    when v.run > v.cyc * (1 + 1e-9) + 1 then false
    when v.cyc > v.t * (1 + 1e-9) + 1 then false
    when v.prev > power(v.s + v.cr, 2) * 1e8 + v.cyc * 1e-6 + 1 then false
    when v.cr > v.s + 0.5 then false                                  -- every Yatırım Turu grants >= 1 share
    when v.cr > v.p + 0.5 then false
    when v.ic < 0.5 and v.s > (case when v.cr <= 1e300 / (v.prev + v.cyc * 1e-6 + 1) then sqrt(v.cr * (v.prev + v.cyc * 1e-6 + 1) / 1e8)
                                 else sqrt(v.cr) * sqrt(v.prev + v.cyc * 1e-6 + 1) / 1e4 end) + 0.001 then false
    -- v4.4a: after a Halka Arz, shares may come from earlier cycles too (v4.4 keeps them; compensated v4.3 saves).
    -- Bound: every share came from one Yatırım Turu (or, v4.4, a banked Halka Arz round), each round's run earnings
    -- are part of totalEarned, so shares <= accel * sqrt(rounds * totalEarned / 1e8) + 1 (Cauchy-Schwarz).
    -- v4.3 saves (format <= 4): no accelerator and no banked rounds, i.e. accel 1 and rounds = prestigeCount.
    when v.ic >= 0.5 and v.s > (case when v.cr <= 1e300 / (v.prev + v.cyc * 1e-6 + 1) then sqrt(v.cr * (v.prev + v.cyc * 1e-6 + 1) / 1e8)
                                 else sqrt(v.cr) * sqrt(v.prev + v.cyc * 1e-6 + 1) / 1e4 end) + 0.001
         and v.s > v.share_cap then false
    when v.ic < 0.5 and v.older > v.t * 1e-6 + 1 then false
    when v.ic < 0.5 and abs(v.cr - v.p) > 0.5 then false               -- no Halka Arz yet: every round is in this cycle
    when v.ic >= 0.5 and v.p < v.cr + 3 * v.ic - 0.5 then false          -- each Halka Arz needed 3 earlier rounds (CFG.halkaArz.rounds)
    when v.ic >= 0.5 and v.ge < v.ic - 0.5 then false                    -- every Halka Arz grants >= 1 Borsa Payı
    when v.ic >= 0.5 and v.ge > v.ic * 12 + 0.5                          -- 12 = max stagePays (v4.3 and v4.4)
         and v.older * (1 + 1e-6) + 1 < v.ic * power(greatest(v.ge - v.ic, 0) / v.ic, 3) * 1e14 then false
    -- B) time x max income (v4.3 formula; v4.4 saves: stage bonus 1 + 0.1 x 10, accelerated share cap).
    -- v4.5: the employee tier multiplier 32 (5 old tiers x2) becomes v.tier_mult (config: 32 x 1.25^14 for the 14 new
    -- tiers 150 ... 10000), and v.base counts units with the piecewise price curve of the config (below).
    else v.t <= 10 * v.e * (
      case when v.ic >= 0.5 then
        v.base * v.tier_mult * 1.1 * 2.4904 * v.stage_mult * 3 * (1 + 0.125 * greatest(v.s, v.share_cap)) * 1.5 * 64
          * (1 + 0.01 * least(v.ge, 50))
        + 20 * 12 * 2 * v.stage_mult * (1 + 0.125 * greatest(v.s, v.share_cap)) * 10 * 10 * 2
        + 1000
      else
        v.base * v.tier_mult * 1.1 * 2.4904 * v.stage_mult * 3 * (1 + 0.1 * v.s) * 32
        + 20 * 12 * v.stage_mult * (1 + 0.1 * v.s) * 10 * 2
        + 1000
      end)
  end
  from (
    select n.*,
      greatest(n.cyc - n.run, 0) as prev,
      greatest(n.t - n.cyc, 0) as older,
      case when n.v44 then 2.0 else 1.8 end as stage_mult,
      -- v4.4b: same value as v4.4a; the product is taken only when it cannot overflow float8, else sqrt(x) * sqrt(t) / 1e4
      case when n.v44 then (1 + 0.1 * least(greatest(n.ge, 0), 40))
                           * (case when greatest(n.p + n.ic, 0) <= 1e300 / greatest(n.t, 1) then sqrt(greatest(n.p + n.ic, 0) * n.t / 1e8)
                                   else sqrt(greatest(n.p + n.ic, 0)) * sqrt(greatest(n.t, 0)) / 1e4 end) + 1
           else (case when greatest(n.p, 0) <= 1e300 / greatest(n.t, 1) then sqrt(greatest(n.p, 0) * n.t / 1e8)
                      else sqrt(greatest(n.p, 0)) * sqrt(greatest(n.t, 0)) / 1e4 end) + 1 end as share_cap,
      -- v4.5: units of each employee from the piecewise price curve of kodhane_rule.score_curve (growth = [[first unit,
      -- price growth], ...], the last growth goes on after the last start). Unit i costs b x prod(growth up to i); with a
      -- Halka Arz (ic >= 0.5) the growth above 1 is cut by ik_factor (İK Anlaşması, 0.14 / 0.15) x borsa_cut (Borsa 1,
      -- x0.8; generous: assumed as soon as there is a Halka Arz). Units = the most a player could buy with ALL of
      -- totalEarned for this one employee (inverse of the cumulative cost, segment by segment). With growth [[0, 1.15]]
      -- this is exactly the v4.4b formula floor(ln(t x 0.15 / b + 1) / ln 1.15) (0.14 / 1.14 with a Halka Arz); the
      -- result is never below that v4.4b count (greatest), so no curve in the config can make the rule stricter than B.
      (select 10 + coalesce(sum(case when n.t >= q.need then g.tps * u.units else 0 end), 0)
         from (values ('stajyer', 15::float8, 0.2::float8, 0::float8, 0::float8), ('junior', 100, 1, 0, 0), ('senior', 1100, 8, 0, 0),
                      ('tasarimci', 12000, 47, 0, 0), ('pm', 130000, 260, 0, 0), ('ai', 1400000, 1400, 0, 0), ('sunucu', 20000000, 7800, 0, 0),
                      ('ofis', 330000000, 44000, 0, 0), ('veri', 1.5e9, 1.2e5, 1e11, 'Infinity'), ('arge', 6.0e9, 3.0e5, 1e13, 1e15),
                      ('cip', 2.5e10, 8.0e5, 1e15, 'Infinity'), ('yzlab', 1.2e11, 2.5e6, 1e19, 1e19), ('mars', 3.0e12, 2.0e7, 1e23, 1e23)
              ) g(id, b, tps, need44, need43)
         cross join lateral (select case when n.v44 then g.need44 else g.need43 end as need) q
         cross join lateral (
           -- never fewer units than v4.4b counts (a curve that is costlier somewhere, e.g. F3 100-300, stays as generous)
           select greatest(floor(ln(n.t * (case when n.ic >= 0.5 then 0.14 else 0.15 end) / g.b + 1)
                                 / ln(case when n.ic >= 0.5 then 1.14 else 1.15 end)),
                           coalesce(max(least(sg.a + floor(ln((n.t - g.b * sg.cstart) * (sg.gg - 1) / (g.b * exp(sg.lstart)) + 1) / ln(sg.gg)),
                                     coalesce(sg.nxt, 'Infinity'::float8))), 0)) as units
             from (select s2.a, s2.nxt, s2.gg, s2.lstart,
                          coalesce(sum(exp(s2.lstart) * (power(s2.gg, s2.nxt - s2.a) - 1) / (s2.gg - 1))
                                     over (order by s2.a rows between unbounded preceding and 1 preceding), 0) as cstart
                     from (select s1.a, s1.nxt, s1.gg,
                                  coalesce(sum((s1.nxt - s1.a) * ln(s1.gg)) over (order by s1.a rows between unbounded preceding and 1 preceding), 0) as lstart
                             from (select (e.x ->> 0)::float8 as a, lead((e.x ->> 0)::float8) over (order by e.i) as nxt,
                                          1 + ((e.x ->> 1)::float8 - 1) * (case when n.ic >= 0.5 then n.ik_factor * n.borsa_cut else 1 end) as gg
                                     from jsonb_array_elements(n.curve) with ordinality e(x, i)) s1) s2) sg
            where n.t >= g.b * sg.cstart) u) as base,
      -- gens: known ids, number >= 0 (or null), none owned before its stage (v4.4 need or v4.3 need)
      not exists (
        select 1 from jsonb_each(n.gens) x
        left join (values ('stajyer', 0::float8, 0::float8), ('junior', 0, 0), ('senior', 0, 0), ('tasarimci', 0, 0), ('pm', 0, 0),
                          ('ai', 0, 0), ('sunucu', 0, 0), ('ofis', 0, 0), ('veri', 1e11, 'Infinity'), ('arge', 1e13, 1e15),
                          ('cip', 1e15, 'Infinity'), ('yzlab', 1e19, 1e19), ('mars', 1e23, 1e23)) k(id, need44, need43) on k.id = x.key
        where jsonb_typeof(x.value) <> 'null'
          and case when k.id is null or jsonb_typeof(x.value) <> 'number' then true
                   when (x.value::text)::numeric < 0 then true
                   else (x.value::text)::numeric > 0 and n.t < case when n.v44 then k.need44 else k.need43 end end) as gens_ok,
      -- stage IDs (v4.4 saves only): string, known, reachable with totalEarned
      case when not n.v44 then not (n.o ? 'stageId' or n.o ? 'stageBestId' or n.o ? 'cycleStageId')
           else not exists (
             select 1 from unnest(array['stageId', 'stageBestId', 'cycleStageId']) f(k)
             left join (values ('freelancer', 0::float8), ('ev_ofisi', 1000), ('butik_studyo', 50000), ('ajans', 1000000), ('dev_ajans', 50000000),
                               ('global_holding', 2500000000), ('unicorn', 1e11), ('sirketler_grubu', 1e13), ('teknoloji_devi', 1e15),
                               ('yapay_zeka_lab', 1e19), ('asama_1e21', 1e21), ('mars_ofisi', 1e23)) st(id, at) on st.id = n.o ->> f.k
             where n.o ? f.k and jsonb_typeof(n.o -> f.k) <> 'null'
               and case when jsonb_typeof(n.o -> f.k) <> 'string' or st.id is null then true
                        else coalesce(st.at > n.t * (1 + 1e-9) + 1, true) end) end as stage_ids_ok
    from (
      select r.*,
        case when r.t_ok then (r.o ->> 'totalEarned')::float8 end as t,
        case when r.run_ok and jsonb_typeof(r.o -> 'runEarned') = 'number' then (r.o ->> 'runEarned')::float8
             when r.t_ok then (r.o ->> 'totalEarned')::float8 end as run,
        case when r.cyc_ok and jsonb_typeof(r.o -> 'cycleEarned') = 'number' then (r.o ->> 'cycleEarned')::float8
             when r.t_ok then (r.o ->> 'totalEarned')::float8 end as cyc,
        coalesce(r.num ->> 'shares', '0')::float8 as s,
        coalesce(r.num ->> 'prestigeCount', '0')::float8 as p,
        coalesce(r.num ->> 'cycleRounds', r.num ->> 'prestigeCount', '0')::float8 as cr,   -- v3 saves: every round is in this cycle
        coalesce(r.num ->> 'ipoCount', '0')::float8 as ic,
        coalesce(r.num ->> 'ipoSharesEarned', '0')::float8 as ge,
        -- save format: 5 = v4.4 (saveVersion / version, whichever is higher; v4.3.0 keeps 'version' 5 of a loaded v4.4 save)
        greatest(coalesce(r.num ->> 'saveVersion', '0')::float8, coalesce(r.num ->> 'version', '0')::float8) >= 5 as v44,
        case when jsonb_typeof(r.o -> 'gens') = 'object' then r.o -> 'gens' else '{}'::jsonb end as gens,
        -- v4.5: price curve + tier multiplier (one active row of kodhane_rule.score_curve)
        c.growth as curve, c.tier_mult, c.ik_factor, c.borsa_cut,
        -- elapsed seconds (+1 h slack), from max(startedAt, launch) to max(now, lastSaved), never more than since launch
        least(greatest(r.nowms - r.st, coalesce(r.ls - r.st, 0), 0), greatest(r.nowms - r.launch, 0)) / 1000.0 + 3600 as e
      from (
        select i.o, i.nowms, i.launch,
          (select bool_and(jsonb_typeof(i.o -> k) is null or jsonb_typeof(i.o -> k) in ('number', 'null'))
             from unnest(array['totalEarned', 'runEarned', 'cycleEarned', 'shares', 'prestigeCount', 'cycleRounds', 'ipoCount',
                               'ipoSharesEarned', 'startedAt', 'lastSaved', 'saveVersion', 'version']) k) as types_ok,
          case when jsonb_typeof(i.o -> 'totalEarned') = 'number'
               then (i.o ->> 'totalEarned')::numeric between 0 and 1e300 else false end as t_ok,          -- v4.4b: 1e300 (was float8 max)
          case when jsonb_typeof(i.o -> 'runEarned') = 'number'
               then abs((i.o ->> 'runEarned')::numeric) <= 1e300 else true end as run_ok,
          case when jsonb_typeof(i.o -> 'cycleEarned') = 'number'
               then abs((i.o ->> 'cycleEarned')::numeric) <= 1e300 else true end as cyc_ok,
          -- counters clamped to +-1e51 (v4.4b; was 1e100): every product below stays inside float8, > 1e50 is refused above
          (select coalesce(jsonb_object_agg(k, least(greatest((i.o ->> k)::numeric, -1e51), 1e51)), '{}'::jsonb)
             from unnest(array['shares', 'prestigeCount', 'cycleRounds', 'ipoCount', 'ipoSharesEarned', 'saveVersion', 'version']) k
            where jsonb_typeof(i.o -> k) = 'number') as num,
          greatest(coalesce(case when jsonb_typeof(i.o -> 'startedAt') = 'number'
                                 then least(greatest((i.o ->> 'startedAt')::numeric, -1e15), 1e15)::float8 end, i.launch), i.launch) as st,
          case when jsonb_typeof(i.o -> 'lastSaved') = 'number'
               then least(greatest((i.o ->> 'lastSaved')::numeric, -1e15), 1e15)::float8 end as ls
        from (select case when jsonb_typeof(d) = 'object' then d end as o,
                     extract(epoch from p_now)::float8 * 1000 as nowms,
                     extract(epoch from timestamptz '2026-09-27 00:00:00+00')::float8 * 1000 as launch) i
        where i.o is not null
      ) r
      cross join kodhane_rule.active_score_curve() c   -- <score_curve_source>
    ) n
  ) v
), false)
-- </v4_5_body>
$function$;

comment on function public.kodhane_score_plausible(jsonb, timestamptz) is 'Kodhane leaderboard heuristic v4.5 (migration 20261003080000; = v4.4b of 20260929204000 plus: stage asama_1e21, employee tier multiplier and piecewise price curve from the active row of kodhane_rule.score_curve, read through kodhane_rule.active_score_curve(); game v4.3.x, v4.4 and v4.5): false if a save''s totalEarned is implausible. v4.4b: v4.3 rule plus Halka Arz share cap, v4.4 accelerator, banked rounds, stage bonus x2.0, Veri Merkezi / Çip Fabrikası, float8 bounds. Generous by design.';

-- ---------------------------------------------------------------- stage catalogue: asama_1e21 (= game.js v4.5 STAGES)
-- B's catalogue (20260929204000) plus the v4.5 stage asama_1e21 (at 1e21) between yapay_zeka_lab and mars_ofisi.
-- Without it kodhane_stage_id_max ignores asama_1e21 (rank -1) and the leaderboard lists such a player with
-- yapay_zeka_lab. Rank and CHECK change together: with the new rank the B trigger can write 'asama_1e21'.
-- kodhane_stage_legacy_id (v4.3 numbers), kodhane_stage_id_max, the trigger function and leaderboard v7 are unchanged.
create or replace function public.kodhane_stage_rank(p_id text) returns integer
language sql immutable parallel safe set search_path to '' as $$
  select coalesce(array_position(array['freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding', 'unicorn',
                                       'sirketler_grubu', 'teknoloji_devi', 'yapay_zeka_lab', 'asama_1e21', 'mars_ofisi']::text[], p_id) - 1, -1)
$$;
create or replace function public.kodhane_stage_at(p_id text) returns numeric
language sql immutable parallel safe set search_path to '' as $$
  select (array[0, 1e3, 5e4, 1e6, 5e7, 2.5e9, 1e11, 1e13, 1e15, 1e19, 1e21, 1e23]::numeric[])[public.kodhane_stage_rank(p_id) + 1]
$$;
comment on function public.kodhane_stage_rank(text) is 'v4.5 stage catalogue (migration 20261003080000): B (20260929204000) + asama_1e21 between yapay_zeka_lab and mars_ofisi.';
comment on function public.kodhane_stage_at(text) is 'v4.5 stage catalogue (migration 20261003080000): B (20260929204000) + asama_1e21 at 1e21.';
-- (create or replace keeps owner and ACL: EXECUTE postgres + service_role, as after B)
do $c$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.kodhane_saves'::regclass and conname = 'kodhane_saves_best_stage_id_known'
                    and pg_get_constraintdef(oid) like '%asama_1e21%') then
    alter table public.kodhane_saves drop constraint if exists kodhane_saves_best_stage_id_known;
    alter table public.kodhane_saves add constraint kodhane_saves_best_stage_id_known
      check (best_stage_id is null or best_stage_id in ('freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding',
                                                        'unicorn', 'sirketler_grubu', 'teknoloji_devi', 'yapay_zeka_lab', 'asama_1e21', 'mars_ofisi'));
      -- (literal list, no function call: a CHECK runs as the writing role, which cannot execute kodhane_ helpers)
  end if;
end $c$;

-- every save whose best_stage_id becomes 'asama_1e21' (backfill below or the B trigger later) is recorded once with
-- its value before, so the rollback can put exactly that value back (rows are deleted with the save)
create table if not exists kodhane_rule.stage_1e21_log (
  user_id uuid primary key references public.kodhane_saves (user_id) on delete cascade,
  old_best_stage_id text,
  source text not null constraint stage_1e21_log_source_check check (source in ('backfill', 'trigger')),
  logged_at timestamptz not null default now()
);
alter table kodhane_rule.stage_1e21_log owner to postgres;
alter table kodhane_rule.stage_1e21_log enable row level security;
revoke all on table kodhane_rule.stage_1e21_log from public, anon, authenticated, service_role;
comment on table kodhane_rule.stage_1e21_log is
  'Kodhane v4.5 (migration 20261003080000): saves whose best_stage_id became asama_1e21, with the value before (first change only). Read by the rollback to restore it; deleted with the save.';
create or replace function kodhane_rule.stage_1e21_log_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into kodhane_rule.stage_1e21_log (user_id, old_best_stage_id, source)
  values (new.user_id, case when tg_op = 'UPDATE' then old.best_stage_id end, 'trigger')
  on conflict (user_id) do nothing;
  return null;
end $$;
alter function kodhane_rule.stage_1e21_log_write() owner to postgres;
revoke all on function kodhane_rule.stage_1e21_log_write() from public, anon, authenticated, service_role;
drop trigger if exists kodhane_saves_zz_stage_1e21_log_ins on public.kodhane_saves;
create trigger kodhane_saves_zz_stage_1e21_log_ins after insert on public.kodhane_saves
  for each row when (new.best_stage_id = 'asama_1e21') execute function kodhane_rule.stage_1e21_log_write();
drop trigger if exists kodhane_saves_zz_stage_1e21_log_upd on public.kodhane_saves;
create trigger kodhane_saves_zz_stage_1e21_log_upd after update on public.kodhane_saves
  for each row when (new.best_stage_id = 'asama_1e21' and old.best_stage_id is distinct from 'asama_1e21')
  execute function kodhane_rule.stage_1e21_log_write();

-- backfill: saves whose vetted stage (plausible under v4.5, totalEarned >= 1e21) is asama_1e21 but whose
-- best_stage_id is lower (B listed them with yapay_zeka_lab). Expected 0 on live before the v4.5 push. Only
-- best_stage_id is written, with the save triggers off (session_replication_role, superuser install): no revision
-- change for the clients, no progress log event. The rows are logged first (kodhane_rule.stage_1e21_log).
create temp table _sr_bf on commit drop as
  select k.user_id, k.best_stage_id as old_best_stage_id
    from public.kodhane_saves k
   where public.kodhane_stage_rank(k.best_stage_id) < public.kodhane_stage_rank('asama_1e21')
     and public.kodhane_save_vetted_stage_id(k.data) = 'asama_1e21';
select concat_ws('|', 'INFO', 'stage_1e21_backfill', 'rows', coalesce(sum(n), 0), 'from', coalesce(string_agg(o || ':' || n, ',' order by o), '-'))
  from (select coalesce(old_best_stage_id, 'NULL') as o, count(*) as n from _sr_bf group by 1) x;
select concat_ws('|', 'BFROW', user_id, coalesce(old_best_stage_id, 'NULL'), 'asama_1e21') from _sr_bf order by user_id;
do $bf$
declare n bigint; m bigint;
begin
  select count(*) into n from _sr_bf;
  if n = 0 then return; end if;
  insert into kodhane_rule.stage_1e21_log (user_id, old_best_stage_id, source)
    select user_id, old_best_stage_id, 'backfill' from _sr_bf
  on conflict (user_id) do nothing;
  perform set_config('session_replication_role', 'replica', true);
  update public.kodhane_saves k set best_stage_id = 'asama_1e21' from _sr_bf b where b.user_id = k.user_id;
  get diagnostics m = row_count;
  perform set_config('session_replication_role', 'origin', true);
  if m <> n then
    raise exception 'v4.5 score rule: stage backfill wrote % of % rows; rolled back', m, n;
  end if;
end $bf$;
drop table _sr_bf;

-- privileges of kodhane_score_plausible are unchanged (create or replace keeps owner and ACL)
do $post$
begin
  if not public.kodhane_score_plausible('{"totalEarned": 0}'::jsonb, now()) then
    raise exception 'v4.5 score rule: an empty save is not plausible after the install; rolled back';
  end if;
  if (select count(*) from kodhane_rule.score_curve where active) <> 1 then
    raise exception 'v4.5 score rule: score_curve needs exactly one active row; rolled back';
  end if;
end $post$;
commit;
