-- Kodhane v4.4 backend, PACKAGE B: stage IDs (Unicorn / Şirketler Grubu) for the leaderboard + save-version guard.
-- Applies ON TOP OF package A (20260929203000_v4_4a_kodhane_score_plausible.sql; refuses without it).
--   psql "$DB_URL" -X -1 -v ON_ERROR_STOP=1 -f supabase/migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql
-- Rollback: supabase/rollback/20260929204000_v4_4b_kodhane_stage_ids_version_guard.rollback.sql (B only; A stays).
-- Idempotent. No data write (no backfill): old rows keep best_stage_id NULL and are read through the legacy mapping.
--
-- What it adds (only kodhane_ objects; v2.2 functions, kodhane_leaderboard v6 and every Açık Ofis object are untouched):
--   * kodhane_score_plausible v4.4b = the v4.4a rule (package A) with float8 bounds, no separate A revision: counters
--     (shares, prestigeCount, cycleRounds, ipoCount, ipoSharesEarned) above 1e50 and totalEarned / runEarned / cycleEarned
--     beyond 1e300 return false instead of SQLSTATE 22003 (overflow); share cap and the share check take a product only
--     when it fits float8. Same result as v4.4a for every save inside those bounds. A row with such values (e.g. written
--     by an admin with session_replication_role = replica) no longer breaks kodhane_leaderboard / _v7 for everybody.
--     Rollback of B puts the v4.4a definition back verbatim.
--   * kodhane_saves.best_stage_id text (NULL = derive from best_stage): best stage by v4.4 stage ID, never decreases,
--     written only by the trigger kodhane_saves_v44_stage_id (vetted like best_stage: plausible save, stage reachable).
--   * kodhane_leaderboard_v7(p_limit): the Kodhane list of v6 (same rank / nickname / score / stage / is_me / status)
--     plus stage_id. v6 stays as is for v4.3.x / v4.4.0 clients and for Açık Ofis (p_game 'acik_ofis').
--   * kodhane_saves_a_version_guard (BEFORE UPDATE, fires before the v2.2 trigger): a player write whose
--     data.saveVersion is LOWER than the stored data.saveVersion, while the stored save is v4.4 format (saveVersion >= 5),
--     is refused with SQLSTATE PT426 (PostgREST: HTTP 426), message 'save_version_too_old'. A save without saveVersion
--     counts as the oldest (0). Format 4 saves (v4.3.0 / v4.3.1) are not guarded: both clients write the same format, so a
--     v4.3.0 tab (no saveVersion) may keep writing over a v4.3.1 save. Only data.saveVersion is read, never data.version:
--     v4.3.0 keeps the 'version' 5 of a loaded v4.4 save while dropping its v4.4 fields. Exempt: writes whose
--     current_user is postgres / supabase_admin / service_role, i.e. manual SQL, the service key and the SECURITY
--     DEFINER RPCs kodhane_reset_save / kodhane_restore_save (the player explicitly asked for that save).
--     Emergency switch without rollback: ALTER TABLE public.kodhane_saves DISABLE TRIGGER kodhane_saves_a_version_guard;
do $guard$
begin
  if to_regclass('public.kodhane_saves') is null or to_regprocedure('public.kodhane_leaderboard(integer,text)') is null then
    raise exception 'v4.4b: wrong target (public.kodhane_saves / kodhane_leaderboard missing)';
  end if;
  if not exists (select 1 from pg_attribute where attrelid = 'public.kodhane_saves'::regclass and attname = 'best_stage' and not attisdropped) then
    raise exception 'v4.4b: Kodhane v2.2 (20260928160000) is not applied here';
  end if;
  if coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') not like 'Kodhane leaderboard heuristic v4.4a %'
     and coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') not like 'Kodhane leaderboard heuristic v4.4b %' then
    raise exception 'v4.4b: package A (20260929203000_v4_4a_kodhane_score_plausible.sql) is not applied; apply A first';
  end if;
end $guard$;

-- ---------------------------------------------------------------- kodhane_score_plausible v4.4b (float8 bounds)
-- CREATE OR REPLACE keeps owner and grants. Body between the markers; differences to v4.4a are marked 'v4.4b'.
create or replace function public.kodhane_score_plausible(d jsonb, p_now timestamptz default now())
 returns boolean
 language sql
 stable parallel safe
 set search_path to ''
as $function$
-- <v4_4b_body>
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
    -- B) time x max income (v4.3 formula; v4.4 saves: stage bonus 1 + 0.1 x 10, accelerated share cap)
    else v.t <= 10 * v.e * (
      case when v.ic >= 0.5 then
        v.base * 32 * 1.1 * 2.4904 * v.stage_mult * 3 * (1 + 0.125 * greatest(v.s, v.share_cap)) * 1.5 * 64
          * (1 + 0.01 * least(v.ge, 50))
        + 20 * 12 * 2 * v.stage_mult * (1 + 0.125 * greatest(v.s, v.share_cap)) * 10 * 10 * 2
        + 1000
      else
        v.base * 32 * 1.1 * 2.4904 * v.stage_mult * 3 * (1 + 0.1 * v.s) * 32
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
      (select 10 + coalesce(sum(case when n.t >= q.need then g.tps * floor(ln(n.t * (case when n.ic >= 0.5 then 0.14 else 0.15 end) / g.b + 1)
                                                          / ln(case when n.ic >= 0.5 then 1.14 else 1.15 end)) else 0 end), 0)
         from (values ('stajyer', 15::float8, 0.2::float8, 0::float8, 0::float8), ('junior', 100, 1, 0, 0), ('senior', 1100, 8, 0, 0),
                      ('tasarimci', 12000, 47, 0, 0), ('pm', 130000, 260, 0, 0), ('ai', 1400000, 1400, 0, 0), ('sunucu', 20000000, 7800, 0, 0),
                      ('ofis', 330000000, 44000, 0, 0), ('veri', 1.5e9, 1.2e5, 1e11, 'Infinity'), ('arge', 6.0e9, 3.0e5, 1e13, 1e15),
                      ('cip', 2.5e10, 8.0e5, 1e15, 'Infinity'), ('yzlab', 1.2e11, 2.5e6, 1e19, 1e19), ('mars', 3.0e12, 2.0e7, 1e23, 1e23)
              ) g(id, b, tps, need44, need43)
         cross join lateral (select case when n.v44 then g.need44 else g.need43 end as need) q) as base,
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
                               ('yapay_zeka_lab', 1e19), ('mars_ofisi', 1e23)) st(id, at) on st.id = n.o ->> f.k
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
    ) n
  ) v
), false)
-- </v4_4b_body>
$function$;

comment on function public.kodhane_score_plausible(jsonb, timestamptz) is 'Kodhane leaderboard heuristic v4.4b (package B, migration 20260929204000; = v4.4a rule of 20260929203000 plus float8 bounds: counters > 1e50 or totalEarned / runEarned / cycleEarned beyond 1e300 -> false, no overflow error; game v4.3.x and v4.4): false if a save''s totalEarned is implausible. v4.3 rule plus: after a Halka Arz shares may come from earlier cycles (v4.4 keepShares / compensated saves), capped by accel x sqrt(rounds x totalEarned / 1e8); v4.4 saves (saveVersion/version >= 5): accelerator, banked rounds, stage bonus x2.0, Veri Merkezi / Çip Fabrikası; format <= 4 saves with v4.4-only fields are rejected. Generous by design.';


-- ---------------------------------------------------------------- stage catalogue (= game.js v4.4 STAGES / LEGACY_STAGE_IDS)
-- rank of a v4.4 stage ID (order of game.js STAGES), -1 = unknown
create or replace function public.kodhane_stage_rank(p_id text) returns integer
language sql immutable parallel safe set search_path to '' as $$
  select coalesce(array_position(array['freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding', 'unicorn',
                                       'sirketler_grubu', 'teknoloji_devi', 'yapay_zeka_lab', 'mars_ofisi']::text[], p_id) - 1, -1)
$$;
-- minimum totalEarned of a stage ID (game.js STAGES[].at), NULL = unknown
create or replace function public.kodhane_stage_at(p_id text) returns numeric
language sql immutable parallel safe set search_path to '' as $$
  select (array[0, 1e3, 5e4, 1e6, 5e7, 2.5e9, 1e11, 1e13, 1e15, 1e19, 1e23]::numeric[])[public.kodhane_stage_rank(p_id) + 1]
$$;
-- stage ID of a legacy (v4.3) stage number = best_stage / data.stage (Unicorn / Şirketler Grubu have none: Global Holding)
create or replace function public.kodhane_stage_legacy_id(p_stage integer) returns text
language sql immutable parallel safe set search_path to '' as $$
  select case when p_stage is null then null else
    (array['freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding', 'teknoloji_devi', 'yapay_zeka_lab',
           'mars_ofisi']::text[])[least(8, greatest(0, p_stage)) + 1] end
$$;
-- highest-ranked known stage ID of the three (NULLs / unknown IDs ignored)
create or replace function public.kodhane_stage_id_max(a text, b text, c text) returns text
language sql immutable parallel safe set search_path to '' as $$
  select x from unnest(array[a, b, c]) x where public.kodhane_stage_rank(x) >= 0 order by public.kodhane_stage_rank(x) desc limit 1
$$;
-- stage ID claimed by a save (v4.4: data.stageId; older: data.stage through the legacy list), NULL unless reachable with
-- its totalEarned (same idea as kodhane_save_stage_checked); Freelancer (rank 0) counts as NULL like stage 0 there
create or replace function public.kodhane_save_stage_id_checked(d jsonb) returns text
language sql immutable set search_path to '' as $$
  select case when public.kodhane_stage_rank(x.id) > 0 and public.kodhane_save_score(d) > 0
                   and public.kodhane_save_score(d) >= public.kodhane_stage_at(x.id) then x.id end
  from (select case when jsonb_typeof(d -> 'stageId') = 'string' then d ->> 'stageId'
                    when jsonb_typeof(d -> 'stage') = 'number' and (d ->> 'stage')::numeric between 0 and 8
                      then public.kodhane_stage_legacy_id(floor((d ->> 'stage')::numeric)::int) end as id) x
$$;
-- vetted (plausible save only), like kodhane_save_vetted_stage
create or replace function public.kodhane_save_vetted_stage_id(d jsonb) returns text
language plpgsql stable security definer set search_path to '' as $$
declare id text := public.kodhane_save_stage_id_checked(d);
begin
  if id is not null and coalesce(public.kodhane_score_plausible(d, now()), false) then return id; end if;
  return null;
end $$;
-- save format of a write for the version guard: data.saveVersion (v4.3.1+), missing / not a number = 0 (oldest)
create or replace function public.kodhane_save_format_version(d jsonb) returns integer
language sql immutable parallel safe set search_path to '' as $$
  select case when jsonb_typeof(d -> 'saveVersion') = 'number'
              then least(1000000, greatest(0, floor((d ->> 'saveVersion')::numeric)))::int else 0 end
$$;

-- ---------------------------------------------------------------- best_stage_id
alter table public.kodhane_saves add column if not exists best_stage_id text;
do $c$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.kodhane_saves'::regclass and conname = 'kodhane_saves_best_stage_id_known') then
    alter table public.kodhane_saves add constraint kodhane_saves_best_stage_id_known
      check (best_stage_id is null or best_stage_id in ('freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding',
                                                        'unicorn', 'sirketler_grubu', 'teknoloji_devi', 'yapay_zeka_lab', 'mars_ofisi'));
      -- (literal list, no function call: a CHECK runs as the writing role, which cannot execute kodhane_ helpers)
  end if;
end $c$;
comment on column public.kodhane_saves.best_stage_id is
  'v4.4b: all-time best stage by v4.4 stage ID (NULL = only best_stage, read via kodhane_stage_legacy_id). Never decreases; set by trigger kodhane_saves_v44_stage_id only.';

-- runs after kodhane_saves_before_write (trigger order is by name), so new.best_stage is already final
create or replace function public.kodhane_save_v44_stage_id() returns trigger
language plpgsql security definer set search_path to '' as $$
begin
  new.best_stage_id := public.kodhane_stage_id_max(
    case when tg_op = 'UPDATE' then old.best_stage_id end,          -- never decreases (a client value is ignored)
    public.kodhane_stage_legacy_id(nullif(new.best_stage, 0)),      -- consistent with best_stage
    public.kodhane_save_vetted_stage_id(new.data));                 -- plausible + reachable stage ID of this save
  return new;
end $$;

-- ---------------------------------------------------------------- save-version guard (SECURITY INVOKER: current_user = caller)
-- Self-contained on purpose: as an invoker function it runs as the player's role, which cannot execute kodhane_ helpers.
-- Same formula as kodhane_save_format_version().
create or replace function public.kodhane_save_version_guard() returns trigger
language plpgsql set search_path to '' as $$
declare sv_new int; sv_old int;
begin
  if current_user in ('postgres', 'supabase_admin', 'service_role') then return new; end if;   -- manual SQL, service key, RPCs
  sv_new := case when jsonb_typeof(new.data -> 'saveVersion') = 'number'
                 then least(1000000, greatest(0, floor((new.data ->> 'saveVersion')::numeric)))::int else 0 end;
  sv_old := case when jsonb_typeof(old.data -> 'saveVersion') = 'number'
                 then least(1000000, greatest(0, floor((old.data ->> 'saveVersion')::numeric)))::int else 0 end;
  if sv_new < sv_old and sv_old >= 5 then   -- only v4.4-format saves (saveVersion >= 5) are protected
    raise exception using errcode = 'PT426', message = 'save_version_too_old',
      detail = format('sent saveVersion %s, stored saveVersion %s', sv_new, sv_old),
      hint = 'This game version is older than the cloud save. Update the game (reload the page); do not retry this write.';
  end if;
  return new;
end $$;

drop trigger if exists kodhane_saves_a_version_guard on public.kodhane_saves;
create trigger kodhane_saves_a_version_guard before update on public.kodhane_saves
  for each row execute function public.kodhane_save_version_guard();
drop trigger if exists kodhane_saves_v44_stage_id on public.kodhane_saves;
create trigger kodhane_saves_v44_stage_id before insert or update on public.kodhane_saves
  for each row execute function public.kodhane_save_v44_stage_id();

-- ---------------------------------------------------------------- kodhane_leaderboard_v7 (Kodhane only; v6 unchanged)
create or replace function public.kodhane_leaderboard_v7(p_limit integer default 50)
returns table(rank bigint, nickname text, score numeric, stage integer, stage_id text, is_me boolean, status text)
language plpgsql stable security definer set search_path to '' as $function$
#variable_conflict use_column
declare
  lim int := least(100, greatest(1, coalesce(p_limit, 50)));
  uid uuid := auth.uid();
begin
  return query
  with src as materialized (
    select p.user_id, p.nickname, p.created_at, p.hidden, s.data, s.best_score, s.best_stage, s.best_stage_id,
           case when jsonb_typeof(s.data -> 'totalEarned') = 'number' then (s.data ->> 'totalEarned')::numeric end as n_cur
    from public.kodhane_profiles p
    join public.kodhane_saves s on s.user_id = p.user_id
  ), vetted as materialized (
    select src.*, (n_cur is not null and n_cur >= 0 and n_cur <= 1.7976931348623157e308
                   and public.kodhane_score_plausible(data)) as cur_ok
    from src
  ), judged as (
    select user_id, nickname, created_at,
           greatest(best_score, case when cur_ok then n_cur else 0 end) as n,
           case when hidden then 'hidden' when best_score > 0 or cur_ok then 'ok' else 'pending' end as status,
           greatest(best_stage, case when cur_ok then public.kodhane_save_stage_checked(data) else 0 end) as stage,
           best_stage_id, case when cur_ok then public.kodhane_save_stage_id_checked(data) end as cur_stage_id
    from vetted
  ), ranked as (
    select user_id, nickname, n as score, stage,
           public.kodhane_stage_id_max(best_stage_id, public.kodhane_stage_legacy_id(stage), cur_stage_id) as stage_id,
           rank() over (order by n desc) as rank,
           row_number() over (order by n desc, created_at, nickname) as rn
    from judged where status = 'ok'
  ), out as (
    select r.rn as k, r.rank, r.nickname, r.score, r.stage, r.stage_id, coalesce(r.user_id = uid, false) as is_me, 'ok'::text as status
    from ranked r
    where r.rn <= lim or r.user_id = uid
    union all
    select 9223372036854775807, null, j.nickname, null, null, null, true, j.status
    from judged j
    where j.status <> 'ok' and j.user_id = uid
  )
  select o.rank, o.nickname, o.score, o.stage, o.stage_id, o.is_me, o.status from out o order by o.k;
end $function$;

-- ---------------------------------------------------------------- grants / comments
revoke all on function public.kodhane_stage_rank(text), public.kodhane_stage_at(text), public.kodhane_stage_legacy_id(integer),
  public.kodhane_stage_id_max(text, text, text), public.kodhane_save_stage_id_checked(jsonb), public.kodhane_save_vetted_stage_id(jsonb),
  public.kodhane_save_format_version(jsonb), public.kodhane_save_v44_stage_id(), public.kodhane_save_version_guard(),
  public.kodhane_leaderboard_v7(integer) from public;
revoke all on function public.kodhane_stage_rank(text), public.kodhane_stage_at(text), public.kodhane_stage_legacy_id(integer),
  public.kodhane_stage_id_max(text, text, text), public.kodhane_save_stage_id_checked(jsonb), public.kodhane_save_vetted_stage_id(jsonb),
  public.kodhane_save_format_version(jsonb), public.kodhane_save_v44_stage_id(), public.kodhane_save_version_guard(),
  public.kodhane_leaderboard_v7(integer) from anon, authenticated;
grant execute on function public.kodhane_stage_rank(text), public.kodhane_stage_at(text), public.kodhane_stage_legacy_id(integer),
  public.kodhane_stage_id_max(text, text, text), public.kodhane_save_stage_id_checked(jsonb), public.kodhane_save_vetted_stage_id(jsonb),
  public.kodhane_save_format_version(jsonb) to service_role;
grant execute on function public.kodhane_leaderboard_v7(integer) to anon, authenticated, service_role;
comment on function public.kodhane_leaderboard_v7(integer) is
  'Kodhane leaderboard v7 (v4.4b, migration 20260929204000): the Kodhane list of kodhane_leaderboard v6 (same rank, nickname, score, stage = legacy 0..8, is_me, status) plus stage_id (v4.4 stage ID of the all-time best stage: unicorn / sirketler_grubu visible; NULL on the own pending/hidden row). No user ids. Açık Ofis: keep calling kodhane_leaderboard(p_limit, ''acik_ofis'').';
comment on function public.kodhane_save_version_guard() is
  'v4.4b: BEFORE UPDATE guard on kodhane_saves: data.saveVersion lower than stored while stored >= 5 (v4.4 format) -> SQLSTATE PT426 (HTTP 426) save_version_too_old; missing saveVersion = 0; format 4 saves unguarded; data.version is not read; postgres / supabase_admin / service_role (manual SQL, service key, reset/restore RPCs) exempt.';
comment on function public.kodhane_save_v44_stage_id() is 'v4.4b: BEFORE INSERT OR UPDATE on kodhane_saves: maintains best_stage_id (never decreases; vetted like best_stage).';
