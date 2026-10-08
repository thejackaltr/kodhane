-- ROLLBACK of Kodhane v4.4 package A (20260929203000_v4_4a_kodhane_score_plausible.sql): puts the v4.3 rule back
-- verbatim (pg_get_functiondef of the live function before v4.4a; md5(prosrc) c92ea962f18652fad67710a312f6397d) with its comment.
-- Owner and grants are unchanged by CREATE OR REPLACE. Touches nothing else (no data, no other function).
--   psql "$DB_URL" -X -1 -v ON_ERROR_STOP=1 -f supabase/rollback/20260929203000_v4_4a_kodhane_score_plausible.rollback.sql
-- Idempotent (on the v4.3 rule: no-op re-create). Refuses when the current definition is neither v4.4a nor v4.3.
-- Package B must be rolled back first if it is applied (B does not redefine this function, but keep the order B -> A).
do $guard$
declare src text; cmt text;
begin
  select p.prosrc, coalesce(obj_description(p.oid, 'pg_proc'), '') into src, cmt from pg_proc p
   where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure;
  if cmt like 'Kodhane leaderboard heuristic v4.4a %' then raise notice 'v4.4a rollback: restoring the v4.3 rule';
  elsif md5(src) = 'c92ea962f18652fad67710a312f6397d' then raise notice 'v4.4a rollback: v4.3 rule already in place (re-create, no-op)';
  else raise exception 'v4.4a rollback: unexpected kodhane_score_plausible definition (md5(prosrc) %); not overwriting', md5(src);
  end if;
end $guard$;

CREATE OR REPLACE FUNCTION public.kodhane_score_plausible(d jsonb, p_now timestamp with time zone DEFAULT now())
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE PARALLEL SAFE
 SET search_path TO ''
AS $function$
declare
  t float8; run float8; cyc float8; s float8; p float8; cr float8; ic float8; ge float8;
  st float8; ls float8; nowms float8; launch float8; e float8;
  prev float8; older float8; seff float8; base float8 := 10; smult float8; r float8;
  ipo_t constant float8 := 1e14;     -- = CFG.halkaArz.threshold (v4 cube-root saves)
  ipo_maxpay constant float8 := 12;  -- = max(CFG.halkaArz.stagePays) (v4.1: pays per Halka Arz)
  ipo_bonus constant float8 := 0.01; -- = CFG.halkaArz.unspentBonus
  ipo_bonus_cap constant float8 := 50; -- = CFG.halkaArz.unspentCap
  ipo_rounds constant float8 := 3;   -- = CFG.halkaArz.rounds (Yatırım Turu per Halka Arz)
  tree boolean;
  g record;
begin
  if d is null or jsonb_typeof(d -> 'totalEarned') is distinct from 'number' then return false; end if;
  if (d ->> 'totalEarned')::numeric < 0 or (d ->> 'totalEarned')::numeric > 1.7976931348623157e308 then return false; end if;
  t := (d ->> 'totalEarned')::float8;
  run := t; cyc := t;
  if jsonb_typeof(d -> 'runEarned') = 'number' then
    if abs((d ->> 'runEarned')::numeric) > 1.7976931348623157e308 then return false; end if;
    run := (d ->> 'runEarned')::float8;
  end if;
  if jsonb_typeof(d -> 'cycleEarned') = 'number' then
    if abs((d ->> 'cycleEarned')::numeric) > 1.7976931348623157e308 then return false; end if;
    cyc := (d ->> 'cycleEarned')::float8;
  end if;
  s := 0; p := 0; ic := 0; ge := 0;
  if jsonb_typeof(d -> 'shares') = 'number' then s := least((d ->> 'shares')::numeric, 1e300)::float8; end if;
  if jsonb_typeof(d -> 'prestigeCount') = 'number' then p := least((d ->> 'prestigeCount')::numeric, 1e300)::float8; end if;
  cr := p;  -- v3 saves: every round belongs to the current cycle
  if jsonb_typeof(d -> 'cycleRounds') = 'number' then cr := least((d ->> 'cycleRounds')::numeric, 1e300)::float8; end if;
  if jsonb_typeof(d -> 'ipoCount') = 'number' then ic := least((d ->> 'ipoCount')::numeric, 1e300)::float8; end if;
  if jsonb_typeof(d -> 'ipoSharesEarned') = 'number' then ge := least((d ->> 'ipoSharesEarned')::numeric, 1e300)::float8; end if;
  if run < 0 or cyc < 0 or s < 0 or p < 0 or cr < 0 or ic < 0 or ge < 0 then return false; end if;

  nowms := extract(epoch from p_now) * 1000;
  launch := extract(epoch from timestamptz '2026-09-27 00:00:00+00') * 1000;
  st := null; ls := null;
  if jsonb_typeof(d -> 'startedAt') = 'number' then st := least(greatest((d ->> 'startedAt')::numeric, -1e15), 1e15)::float8; end if;
  if jsonb_typeof(d -> 'lastSaved') = 'number' then ls := least(greatest((d ->> 'lastSaved')::numeric, -1e15), 1e15)::float8; end if;
  if st is null or st < launch then st := launch; end if;
  e := greatest(nowms - st, coalesce(ls - st, 0), 0);
  e := least(e, greatest(nowms - launch, 0)) / 1000.0 + 3600;

  -- A) structure
  if run > cyc * (1 + 1e-9) + 1 then return false; end if;
  if cyc > t * (1 + 1e-9) + 1 then return false; end if;
  prev := greatest(cyc - run, 0);
  if prev > power(s + cr, 2) * 1e8 + cyc * 1e-6 + 1 then return false; end if;
  if cr > s + 0.5 then return false; end if;                -- every Yatırım Turu grants >= 1 share
  if cr > p + 0.5 then return false; end if;
  if s > sqrt(cr * (prev + cyc * 1e-6 + 1) / 1e8) + 0.001 then return false; end if;
  older := greatest(t - cyc, 0);
  if ic < 0.5 then
    if older > t * 1e-6 + 1 then return false; end if;
    if abs(cr - p) > 0.5 then return false; end if;           -- no Halka Arz yet: every round is in the current cycle
  else
    if p < cr + ipo_rounds * ic - 0.5 then return false; end if; -- each Halka Arz needed ipo_rounds earlier rounds
    if ge < ic - 0.5 then return false; end if;               -- every Halka Arz grants >= 1 Borsa Payı
    if ge > ic * ipo_maxpay + 0.5
       and older * (1 + 1e-6) + 1 < ic * power(greatest(ge - ic, 0) / ic, 3) * ipo_t then return false; end if;
  end if;

  -- B) time x max income. The Borsa Payı tree (and its multipliers) exists only after a Halka Arz; the new employee
  -- types only after their stage (run earnings >= stage threshold, so totalEarned >= it too; thresholds = game.js STAGES).
  tree := ic >= 0.5;
  seff := s;
  if tree then seff := greatest(s, sqrt(p * t / 1e8) + 1); end if;
  for g in select * from (values (15::float8, 0.2::float8, 0::float8), (100, 1, 0), (1100, 8, 0), (12000, 47, 0), (130000, 260, 0),
                                 (1400000, 1400, 0), (20000000, 7800, 0), (330000000, 44000, 0),
                                 (6.0e9, 3.0e5, 1e15), (1.2e11, 2.5e6, 1e19), (3.0e12, 2.0e7, 1e23)) v(b, tps, need) loop
    if t >= g.need then
      if tree then base := base + g.tps * floor(ln(t * 0.14 / g.b + 1) / ln(1.14));
      else base := base + g.tps * floor(ln(t * 0.15 / g.b + 1) / ln(1.15)); end if;
    end if;
  end loop;
  if tree then
    smult := 1 + 0.125 * seff;
    r := base * 32 * 1.1 * 2.4904 * 1.8 * 3 * smult * 1.5 * 64   -- production with every multiplier, x64 extras (x2 offers)
         * (1 + ipo_bonus * least(ge, ipo_bonus_cap))           -- v4.1 unspent Borsa Payı bonus (unspent <= earned, capped)
         + 20 * 12 * 2 * 1.8 * smult * 10 * 10 * 2              -- 20 clicks/s, all click boosts, crit, flow, viral
         + 1000;                                                -- flat floor (early-game event/task minimums)
  else
    smult := 1 + 0.1 * s;
    r := base * 32 * 1.1 * 2.4904 * 1.8 * 3 * smult * 32         -- as v2: every multiplier, x32 extras
         + 20 * 12 * 1.8 * smult * 10 * 2
         + 1000;
  end if;
  return t <= 10 * e * r;
end $function$;

comment on function public.kodhane_score_plausible(jsonb, timestamptz) is 'Kodhane leaderboard heuristic (v4, game v4.1: stage-based Borsa Payı, unspent bonus, sectors): false if a save''s totalEarned is implausible (see supabase-infra-status.md). Generous by design.';

do $check$
begin
  if (select md5(prosrc) from pg_proc where oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure) <> 'c92ea962f18652fad67710a312f6397d' then
    raise exception 'v4.4a rollback: restored body does not match the v4.3 fingerprint';
  end if;
end $check$;
