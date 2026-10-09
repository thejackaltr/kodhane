-- Rollback of 20261003080000_v4_5_kodhane_score_rule.sql: kodhane_score_plausible back to the v4.4b definition of
-- package B (20260929204000), byte for byte (pg_get_functiondef md5 463f2109c35b825827e57b8098b49947 as after B),
-- schema kodhane_rule (score_curve table, helpers) dropped. B, the progress log and every other object stay.
-- Stage catalogue (kodhane_stage_rank / kodhane_stage_at / CHECK kodhane_saves_best_stage_id_known) back to B byte for
-- byte. WRITES DATA: best_stage_id 'asama_1e21' goes back to its logged value before (rows printed first, see below).
-- kodhane_score_plausible is evaluated when the leaderboard is read, so the leaderboard goes back to the v4.4b
-- judgement immediately (v4.5 saves with asama_1e21 are hidden again).
begin;
do $pre$
begin
  if coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') not like 'Kodhane leaderboard heuristic v4.5 %'
     and coalesce(obj_description('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure, 'pg_proc'), '') not like 'Kodhane leaderboard heuristic v4.4b %' then
    raise exception 'v4.5 score rule rollback: kodhane_score_plausible is neither v4.5 nor v4.4b here; nothing changed';
  end if;
end $pre$;

-- ---------------------------------------------------------------- best_stage_id 'asama_1e21' -> value before (WRITES DATA)
-- Recorded BEFORE any change and printed (RBCOUNT / RBROW lines; the install script runs rollback-preview first and
-- keeps them in its run directory): every save with best_stage_id 'asama_1e21', the value it goes back to = the
-- value logged in kodhane_rule.stage_1e21_log when it became asama_1e21 (NULL possible); a row without a log entry
-- (should not exist) goes to 'yapay_zeka_lab' (B's highest stage below 1e21). Only best_stage_id is written, save
-- triggers off (session_replication_role, superuser): no revision change, no progress log event.
create temp table _sr_rb (user_id uuid primary key, cur text, revert_to text, source text) on commit drop;
do $rb$
begin
  if to_regclass('kodhane_rule.stage_1e21_log') is not null then
    execute 'insert into _sr_rb select k.user_id, k.best_stage_id, l.old_best_stage_id, coalesce(l.source, ''nolog'')
               from public.kodhane_saves k left join kodhane_rule.stage_1e21_log l on l.user_id = k.user_id
              where k.best_stage_id = ''asama_1e21''';
  else
    insert into _sr_rb select k.user_id, k.best_stage_id, null, 'nolog' from public.kodhane_saves k where k.best_stage_id = 'asama_1e21';
  end if;
  update _sr_rb set revert_to = 'yapay_zeka_lab' where source = 'nolog';
end $rb$;
select concat_ws('|', 'RBCOUNT', count(*), 'backfill', count(*) filter (where source = 'backfill'), 'trigger', count(*) filter (where source = 'trigger'),
                 'nolog', count(*) filter (where source = 'nolog')) from _sr_rb;
select concat_ws('|', 'RBROW', user_id, cur, coalesce(revert_to, 'NULL'), source) from _sr_rb order by user_id;
do $rbw$
declare n bigint; m bigint;
begin
  select count(*) into n from _sr_rb;
  if n = 0 then return; end if;
  perform set_config('session_replication_role', 'replica', true);
  update public.kodhane_saves k set best_stage_id = r.revert_to from _sr_rb r where r.user_id = k.user_id and k.best_stage_id = 'asama_1e21';
  get diagnostics m = row_count;
  perform set_config('session_replication_role', 'origin', true);
  if m <> n then raise exception 'v4.5 score rule rollback: restored % of % rows; rolled back', m, n; end if;
end $rbw$;

-- ---------------------------------------------------------------- stage catalogue back to B (20260929204000), byte for byte
drop trigger if exists kodhane_saves_zz_stage_1e21_log_ins on public.kodhane_saves;
drop trigger if exists kodhane_saves_zz_stage_1e21_log_upd on public.kodhane_saves;
alter table public.kodhane_saves drop constraint if exists kodhane_saves_best_stage_id_known;
alter table public.kodhane_saves add constraint kodhane_saves_best_stage_id_known
  check (best_stage_id is null or best_stage_id in ('freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding',
                                                    'unicorn', 'sirketler_grubu', 'teknoloji_devi', 'yapay_zeka_lab', 'mars_ofisi'));
create or replace function public.kodhane_stage_rank(p_id text) returns integer
language sql immutable parallel safe set search_path to '' as $$
  select coalesce(array_position(array['freelancer', 'ev_ofisi', 'butik_studyo', 'ajans', 'dev_ajans', 'global_holding', 'unicorn',
                                       'sirketler_grubu', 'teknoloji_devi', 'yapay_zeka_lab', 'mars_ofisi']::text[], p_id) - 1, -1)
$$;
create or replace function public.kodhane_stage_at(p_id text) returns numeric
language sql immutable parallel safe set search_path to '' as $$
  select (array[0, 1e3, 5e4, 1e6, 5e7, 2.5e9, 1e11, 1e13, 1e15, 1e19, 1e23]::numeric[])[public.kodhane_stage_rank(p_id) + 1]
$$;
comment on function public.kodhane_stage_rank(text) is null;
comment on function public.kodhane_stage_at(text) is null;

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

drop schema if exists kodhane_rule cascade;

do $post$
begin
  if md5(pg_get_functiondef('public.kodhane_score_plausible(jsonb,timestamptz)'::regprocedure)) <> '463f2109c35b825827e57b8098b49947' then
    raise exception 'v4.5 score rule rollback: kodhane_score_plausible is not the v4.4b definition afterwards; rolled back';
  end if;
  if md5(pg_get_functiondef('public.kodhane_stage_rank(text)'::regprocedure)) <> 'e97a3589f1f23fe36991b986480bd509'
     or md5(pg_get_functiondef('public.kodhane_stage_at(text)'::regprocedure)) <> 'b0aa4d9eb67eb4bb284d54c6641be791'
     or (select md5(pg_get_constraintdef(oid)) from pg_constraint where conrelid = 'public.kodhane_saves'::regclass
          and conname = 'kodhane_saves_best_stage_id_known') is distinct from 'f1e8655e57baf17f8c2330d6f252eacf' then
    raise exception 'v4.5 score rule rollback: stage catalogue / CHECK is not B''s afterwards; rolled back';
  end if;
  if exists (select 1 from public.kodhane_saves where best_stage_id = 'asama_1e21')
     or exists (select 1 from _sr_rb r join public.kodhane_saves k using (user_id) where k.best_stage_id is distinct from r.revert_to) then
    raise exception 'v4.5 score rule rollback: a save still has asama_1e21 or not its value before; rolled back';
  end if;
end $post$;
select concat_ws('|', 'CHECK', 'rollback_rows_restored', count(*) filter (where k.best_stage_id is distinct from r.revert_to) = 0, count(*))
  from _sr_rb r left join public.kodhane_saves k using (user_id);
commit;
