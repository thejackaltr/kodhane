-- Kodhane v4.4 PACKAGE A preflight (READ ONLY, SELECT/DO only): right database? v2.2 applied? which plausibility rule
-- is live? and a DRY RUN of the v4.4a rule on every stored Kodhane save (the exact function body of
-- migrations/20260929203000_v4_4a_kodhane_score_plausible.sql, inlined between the markers; tests/v4_4 checks they are identical).
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v4_4a_preflight.sql
-- Prints only counts, anonymous row keys (left(md5(user_id), 16)) and save shapes (no user id, nickname or e-mail).
-- Go / no-go = the last result, one line: EXPECTATION | PASS | ... or EXPECTATION | STOP | <reasons>.
-- Expectation (Yazılım Yöneticisi, 2026-10-01 20:24 TSİ): newly_flagged = 0 and newly_accepted = 0 (no save's rule result
-- changes), and the live rule is the v4.3 rule. Anything else: STOP. (The 07:57 allow list for one save was withdrawn.)
\set ON_ERROR_STOP on
begin read only;
do $pre$
declare src text; lang text; cmt text;
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('public.kodhane_profiles') is null
     or to_regprocedure('public.kodhane_score_plausible(jsonb,timestamptz)') is null
     or to_regprocedure('public.kodhane_leaderboard(integer,text)') is null then
    raise exception 'WRONG TARGET: not the shared Teserix game DB (kodhane_saves / kodhane_profiles / kodhane_score_plausible / kodhane_leaderboard missing)';
  end if;
  if not exists (select 1 from pg_attribute where attrelid = 'public.kodhane_saves'::regclass and attname = 'best_score' and not attisdropped)
     or to_regprocedure('public.kodhane_save_vetted_score(jsonb)') is null then
    raise exception 'Kodhane v2.2 (20260928160000) is not applied: apply v2.2 before package A';
  end if;
  select p.prosrc, l.lanname, coalesce(obj_description(p.oid, 'pg_proc'), '') into src, lang, cmt
    from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure;
  raise notice 'target ok: db=%, user=%, kodhane_saves=% rows; kodhane_score_plausible: %', current_database(), current_user,
    (select count(*) from public.kodhane_saves),
    case when md5(src) = 'c92ea962f18652fad67710a312f6397d' and lang = 'plpgsql' then 'v4.3 rule (expected before A)'
         when cmt like 'Kodhane leaderboard heuristic v4.4a %' then 'v4.4a ALREADY APPLIED'
         else 'UNEXPECTED definition md5(prosrc) ' || md5(src) || ' -> STOP, do not apply A' end;
end $pre$;

-- dry run: current rule vs v4.4a on every stored save, now()
with dry as (
  select ks.user_id, ks.best_score, ks.save_version, ks.data,
         public.kodhane_score_plausible(ks.data) as cur_ok, a4.ok as new_ok
  from public.kodhane_saves ks
  cross join lateral (select ks.data as d, now() as p_now) pf_in
  cross join lateral (
      -- <v4_4a_body>
      select coalesce((
        select case
          -- 0) types: every field the rule reads is a JSON number (or absent/null); totalEarned is required
          when not v.types_ok or not v.t_ok or not v.run_ok or not v.cyc_ok then false
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
          when v.ic < 0.5 and v.s > sqrt(v.cr * (v.prev + v.cyc * 1e-6 + 1) / 1e8) + 0.001 then false
          -- v4.4a: after a Halka Arz, shares may come from earlier cycles too (v4.4 keeps them; compensated v4.3 saves).
          -- Bound: every share came from one Yatırım Turu (or, v4.4, a banked Halka Arz round), each round's run earnings
          -- are part of totalEarned, so shares <= accel * sqrt(rounds * totalEarned / 1e8) + 1 (Cauchy-Schwarz).
          -- v4.3 saves (format <= 4): no accelerator and no banked rounds, i.e. accel 1 and rounds = prestigeCount.
          when v.ic >= 0.5 and v.s > sqrt(v.cr * (v.prev + v.cyc * 1e-6 + 1) / 1e8) + 0.001
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
            case when n.v44 then (1 + 0.1 * least(greatest(n.ge, 0), 40)) * sqrt(greatest((n.p + n.ic) * n.t, 0) / 1e8) + 1
                 else sqrt(greatest(n.p * n.t, 0) / 1e8) + 1 end as share_cap,
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
                     then (i.o ->> 'totalEarned')::numeric between 0 and 1.7976931348623157e308 else false end as t_ok,
                case when jsonb_typeof(i.o -> 'runEarned') = 'number'
                     then abs((i.o ->> 'runEarned')::numeric) <= 1.7976931348623157e308 else true end as run_ok,
                case when jsonb_typeof(i.o -> 'cycleEarned') = 'number'
                     then abs((i.o ->> 'cycleEarned')::numeric) <= 1.7976931348623157e308 else true end as cyc_ok,
                -- counters clamped to +-1e100 (float8-safe; any value that large fails the checks anyway)
                (select coalesce(jsonb_object_agg(k, least(greatest((i.o ->> k)::numeric, -1e100), 1e100)), '{}'::jsonb)
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
      -- </v4_4a_body>
  ) as a4(ok)
)
select count(*) as saves,
       count(*) filter (where cur_ok) as plausible_now,
       count(*) filter (where new_ok) as plausible_v4_4a,
       count(*) filter (where cur_ok and not new_ok) as newly_flagged,
       count(*) filter (where new_ok and not cur_ok) as newly_accepted,
       count(*) filter (where new_ok and not cur_ok and (data->>'totalEarned')::numeric > best_score) as leaderboard_value_moves_on_next_write
  from dry;
-- anonymous shapes of every save whose verdict changes (expected: none)
with dry as (
  select left(md5(ks.user_id::text), 16) as key, ks.revision, ks.data, ks.save_version,
         public.kodhane_score_plausible(ks.data) as cur_ok, a4.ok as new_ok
  from public.kodhane_saves ks
  cross join lateral (select ks.data as d, now() as p_now) pf_in
  cross join lateral (
      -- <v4_4a_body>
      select coalesce((
        select case
          -- 0) types: every field the rule reads is a JSON number (or absent/null); totalEarned is required
          when not v.types_ok or not v.t_ok or not v.run_ok or not v.cyc_ok then false
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
          when v.ic < 0.5 and v.s > sqrt(v.cr * (v.prev + v.cyc * 1e-6 + 1) / 1e8) + 0.001 then false
          -- v4.4a: after a Halka Arz, shares may come from earlier cycles too (v4.4 keeps them; compensated v4.3 saves).
          -- Bound: every share came from one Yatırım Turu (or, v4.4, a banked Halka Arz round), each round's run earnings
          -- are part of totalEarned, so shares <= accel * sqrt(rounds * totalEarned / 1e8) + 1 (Cauchy-Schwarz).
          -- v4.3 saves (format <= 4): no accelerator and no banked rounds, i.e. accel 1 and rounds = prestigeCount.
          when v.ic >= 0.5 and v.s > sqrt(v.cr * (v.prev + v.cyc * 1e-6 + 1) / 1e8) + 0.001
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
            case when n.v44 then (1 + 0.1 * least(greatest(n.ge, 0), 40)) * sqrt(greatest((n.p + n.ic) * n.t, 0) / 1e8) + 1
                 else sqrt(greatest(n.p * n.t, 0) / 1e8) + 1 end as share_cap,
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
                     then (i.o ->> 'totalEarned')::numeric between 0 and 1.7976931348623157e308 else false end as t_ok,
                case when jsonb_typeof(i.o -> 'runEarned') = 'number'
                     then abs((i.o ->> 'runEarned')::numeric) <= 1.7976931348623157e308 else true end as run_ok,
                case when jsonb_typeof(i.o -> 'cycleEarned') = 'number'
                     then abs((i.o ->> 'cycleEarned')::numeric) <= 1.7976931348623157e308 else true end as cyc_ok,
                -- counters clamped to +-1e100 (float8-safe; any value that large fails the checks anyway)
                (select coalesce(jsonb_object_agg(k, least(greatest((i.o ->> k)::numeric, -1e100), 1e100)), '{}'::jsonb)
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
      -- </v4_4a_body>
  ) as a4(ok)
)
select case when cur_ok then 'NEWLY FLAGGED (stop)' else 'newly accepted' end as change, key, revision, save_version,
       data->>'saveVersion' as "saveVersion", data->>'version' as version, data->>'ipoCount' as ipo, data->>'prestigeCount' as rounds,
       data->>'cycleRounds' as cycle_rounds, data->>'shares' as shares, to_char((data->>'totalEarned')::float8, '9.99EEEE') as total
  from dry where cur_ok is distinct from new_ok order by 1, 2;
-- expectation (go / no-go): one line, PASS or STOP with every reason
with dry as (
  select left(md5(ks.user_id::text), 16) as key, ks.revision, ks.updated_at, ks.data,
         public.kodhane_score_plausible(ks.data) as cur_ok, a4.ok as new_ok
  from public.kodhane_saves ks
  cross join lateral (select ks.data as d, now() as p_now) pf_in
  cross join lateral (
      -- <v4_4a_body>
      select coalesce((
        select case
          -- 0) types: every field the rule reads is a JSON number (or absent/null); totalEarned is required
          when not v.types_ok or not v.t_ok or not v.run_ok or not v.cyc_ok then false
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
          when v.ic < 0.5 and v.s > sqrt(v.cr * (v.prev + v.cyc * 1e-6 + 1) / 1e8) + 0.001 then false
          -- v4.4a: after a Halka Arz, shares may come from earlier cycles too (v4.4 keeps them; compensated v4.3 saves).
          -- Bound: every share came from one Yatırım Turu (or, v4.4, a banked Halka Arz round), each round's run earnings
          -- are part of totalEarned, so shares <= accel * sqrt(rounds * totalEarned / 1e8) + 1 (Cauchy-Schwarz).
          -- v4.3 saves (format <= 4): no accelerator and no banked rounds, i.e. accel 1 and rounds = prestigeCount.
          when v.ic >= 0.5 and v.s > sqrt(v.cr * (v.prev + v.cyc * 1e-6 + 1) / 1e8) + 0.001
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
            case when n.v44 then (1 + 0.1 * least(greatest(n.ge, 0), 40)) * sqrt(greatest((n.p + n.ic) * n.t, 0) / 1e8) + 1
                 else sqrt(greatest(n.p * n.t, 0) / 1e8) + 1 end as share_cap,
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
                     then (i.o ->> 'totalEarned')::numeric between 0 and 1.7976931348623157e308 else false end as t_ok,
                case when jsonb_typeof(i.o -> 'runEarned') = 'number'
                     then abs((i.o ->> 'runEarned')::numeric) <= 1.7976931348623157e308 else true end as run_ok,
                case when jsonb_typeof(i.o -> 'cycleEarned') = 'number'
                     then abs((i.o ->> 'cycleEarned')::numeric) <= 1.7976931348623157e308 else true end as cyc_ok,
                -- counters clamped to +-1e100 (float8-safe; any value that large fails the checks anyway)
                (select coalesce(jsonb_object_agg(k, least(greatest((i.o ->> k)::numeric, -1e100), 1e100)), '{}'::jsonb)
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
      -- </v4_4a_body>
  ) as a4(ok)
), chk as (
  select (select md5(p.prosrc) = 'c92ea962f18652fad67710a312f6397d' from pg_proc p
           where p.oid = 'public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure) as live_v43,
         (select count(*) from dry where cur_ok and not new_ok) as flagged,
         (select count(*) from dry where new_ok and not cur_ok) as accepted,
         (select count(*) from dry) as saves
), r as (
  select chk.*, array_remove(array[
      case when not coalesce(live_v43, false) then 'live kodhane_score_plausible is not the v4.3 rule (A already applied or unexpected definition)' end,
      case when flagged > 0 then 'newly_flagged ' || flagged || ' (must be 0)' end,
      case when accepted > 0 then 'newly_accepted ' || accepted || ' (must be 0)' end
    ], null) as why
  from chk
)
select 'EXPECTATION' as expectation, case when cardinality(why) = 0 then 'PASS' else 'STOP' end as result,
       case when cardinality(why) = 0
            then 'newly_flagged 0; newly_accepted 0 (' || saves || ' saves, no rule result changes) -> A may be applied'
            else array_to_string(why, '; ') || ' -> do NOT apply A; send this output to Yazılım Yöneticisi' end as detail
  from r;
commit;
