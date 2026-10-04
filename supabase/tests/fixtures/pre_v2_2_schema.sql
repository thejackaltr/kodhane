-- Pre-v2.2 schema snapshot for local tests ONLY (never run against a real DB from here).
-- Concatenated verbatim from /workspace/kodhane-cloud (not a git repo) on 2026-09-28:
--   schema.sql      sha256 cc5a2dc1c1aee6982803cb9d15bf38bd8d5742c9a7866181d61f503c70acaa13 (kodhane_saves)
--   acik_ofis.sql   sha256 e8222984787ebcc9a9de2296470e1acccd9cf5487787f3460e973ae8031a4d09 (acik_ofis_saves)
--   leaderboard.sql sha256 d9af6adf3f045290f54035c0066e93020e0b6bb051834db59b9779d89a3557f3 (v5: profiles, plausibility, counter, kodhane_leaderboard)
--     (since v2.2 that v5 file is archived verbatim as kodhane-cloud/leaderboard.v5.sql, same sha256; leaderboard.sql is now v6
--      and no longer defines kodhane_leaderboard, the v2.2 migration does)
-- Assumed to equal what is live on supabase.teserix.com (per plans/supabase-infra-status.md).

-- ===================== schema.sql =====================
-- Kodhane cloud save — shared Teserix Supabase (supabase.teserix.com)
-- Namespaced for a shared instance: table public.kodhane_saves, policies kodhane_saves_*.
-- One row per user (user_id = auth.uid()); RLS on; authenticated users may only
-- select/insert/update/delete their OWN row; anon has no access at all.
-- Idempotent: safe to run repeatedly.
begin;

set local role postgres;  -- objects owned by postgres (Supabase convention)

create table if not exists public.kodhane_saves (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  data         jsonb not null,
  save_version int,
  updated_at   timestamptz not null default now()
);

comment on table public.kodhane_saves is
  'Kodhane (thejackaltr.github.io/kodhane) cloud save: one row per auth user; RLS own-row only.';

alter table public.kodhane_saves enable row level security;

-- Privileges: strip Supabase default grants (incl. TRUNCATE/REFERENCES/TRIGGER), then grant only DML to authenticated.
revoke all on table public.kodhane_saves from public;
revoke all on table public.kodhane_saves from anon;
revoke all on table public.kodhane_saves from authenticated;
grant select, insert, update, delete on table public.kodhane_saves to authenticated;

drop policy if exists "kodhane_saves_select_own" on public.kodhane_saves;
drop policy if exists "kodhane_saves_insert_own" on public.kodhane_saves;
drop policy if exists "kodhane_saves_update_own" on public.kodhane_saves;
drop policy if exists "kodhane_saves_delete_own" on public.kodhane_saves;

create policy "kodhane_saves_select_own" on public.kodhane_saves
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "kodhane_saves_insert_own" on public.kodhane_saves
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "kodhane_saves_update_own" on public.kodhane_saves
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "kodhane_saves_delete_own" on public.kodhane_saves
  for delete to authenticated using ((select auth.uid()) = user_id);

commit;

-- Ask PostgREST to pick up the new table.
notify pgrst, 'reload schema';

-- ===================== acik_ofis.sql =====================
-- Kodhane: Açık Ofis cloud save — shared Teserix Supabase (supabase.teserix.com)
-- Own table public.acik_ofis_saves (one row per auth user), same auth users as Kodhane.
-- RLS on; authenticated users may only select/insert/update/delete their OWN row; anon: nothing.
-- Does not touch any kodhane_* object. Idempotent: safe to run repeatedly.
begin;

set local role postgres;  -- objects owned by postgres (Supabase convention)

create table if not exists public.acik_ofis_saves (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  data         jsonb not null,
  save_version int,
  updated_at   timestamptz not null default now()
);

comment on table public.acik_ofis_saves is
  'Kodhane: Açık Ofis (thejackaltr.github.io/kodhane-acik-ofis) cloud save: one row per auth user; RLS own-row only.';

alter table public.acik_ofis_saves enable row level security;

revoke all on table public.acik_ofis_saves from public;
revoke all on table public.acik_ofis_saves from anon;
revoke all on table public.acik_ofis_saves from authenticated;
grant select, insert, update, delete on table public.acik_ofis_saves to authenticated;

drop policy if exists "acik_ofis_saves_select_own" on public.acik_ofis_saves;
drop policy if exists "acik_ofis_saves_insert_own" on public.acik_ofis_saves;
drop policy if exists "acik_ofis_saves_update_own" on public.acik_ofis_saves;
drop policy if exists "acik_ofis_saves_delete_own" on public.acik_ofis_saves;

create policy "acik_ofis_saves_select_own" on public.acik_ofis_saves
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "acik_ofis_saves_insert_own" on public.acik_ofis_saves
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "acik_ofis_saves_update_own" on public.acik_ofis_saves
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "acik_ofis_saves_delete_own" on public.acik_ofis_saves
  for delete to authenticated using ((select auth.uid()) = user_id);

commit;

notify pgrst, 'reload schema';

-- Verification output
select c.relname, c.relrowsecurity as rls, c.relowner::regrole as owner
  from pg_class c where c.oid = 'public.acik_ofis_saves'::regclass;
select grantee, string_agg(privilege_type, ',' order by privilege_type) as privs
  from information_schema.role_table_grants
 where table_schema = 'public' and table_name = 'acik_ofis_saves' group by grantee order by grantee;
select policyname, cmd, roles from pg_policies where schemaname = 'public' and tablename = 'acik_ofis_saves' order by policyname;

-- ===================== leaderboard.sql =====================
-- Kodhane leaderboard ("Sıralama") v5 (Kodhane v4.1 + Açık Ofis v2 list, p_game='acik_ofis') — supabase.teserix.com (dedicated to Kodhane)
-- Opt-in nickname profiles (+ admin hide), server-side score plausibility, SECURITY DEFINER leaderboard RPC.
-- Score = kodhane_saves.data->'totalEarned' (all-time earnings; kept across "Yatırım Turu"/prestige), numeric end to end.
-- v5: p_game='acik_ofis' lists public.acik_ofis_saves (same nickname profiles + admin hide, own plausibility rule).
-- Idempotent: safe to run repeatedly (also upgrades the v1 objects in place). Rollback: leaderboard_rollback.sql
begin;
set local role postgres;

-- ---------------------------------------------------------------- nickname helpers
-- Case-insensitive key for uniqueness. Turkish-aware and locale-independent: I/İ/ı/i all fold to 'i'.
create or replace function public.kodhane_nick_key(n text)
returns text language sql immutable strict parallel safe
set search_path = ''
as $$ select lower(translate(n, 'ÇĞİIÖŞÜı', 'çğiiöşüi')) $$;

-- Normalization used before validation/storage: trim + collapse repeated spaces.
create or replace function public.kodhane_nick_normalize(n text)
returns text language sql immutable strict parallel safe
set search_path = ''
as $$ select regexp_replace(btrim(n), ' {2,}', ' ', 'g') $$;

-- Rules: 3-16 chars (after normalize), letters incl. Turkish, digits, space, '-' and '_'; at least one letter/digit;
-- small TR/EN blocklist + reserved names. Returns null if OK, else a stable code the client maps to Turkish copy.
create or replace function public.kodhane_nick_problem(n text)
returns text language plpgsql immutable parallel safe
set search_path = ''
as $$
declare
  flat text;
  w text;
begin
  if n is null or char_length(n) < 3 then return 'nickname_too_short'; end if;
  if char_length(n) > 16 then return 'nickname_too_long'; end if;
  if n !~ '^[A-Za-z0-9çğıöşüÇĞİÖŞÜ _-]+$' then return 'nickname_invalid_chars'; end if;
  if n !~ '[A-Za-z0-9çğıöşüÇĞİÖŞÜ]' then return 'nickname_invalid_chars'; end if;
  flat := translate(translate(public.kodhane_nick_key(n), ' -_', ''), 'çğöşü013457', 'cgosuoieast');
  if flat in ('admin', 'administrator', 'moderator', 'mod', 'kodhane', 'teserix', 'sistem', 'system', 'support', 'destek', 'root', 'null', 'undefined') then
    return 'nickname_blocked';
  end if;
  if flat in ('amk', 'aq', 'mk', 'oc', 'pic', 'got', 'sik', 'am', 'amq', 'sg', 'siq', 'ass', 'fag', 'cum', 'tits', 'nazi') then
    return 'nickname_blocked';
  end if;
  foreach w in array array['orospu', 'siktir', 'sikis', 'sikik', 'sikim', 'sikey', 'yarrak', 'yarak', 'amcik', 'aminak', 'aminako',
      'gavat', 'pezevenk', 'kahpe', 'yavsak', 'ibne', 'pust', 'kaltak', 'surtuk', 'serefsiz', 'godos', 'dalyarak', 'tassak', 'amcuk',
      'fuck', 'shit', 'bitch', 'cunt', 'nigger', 'nigga', 'whore', 'slut', 'dick', 'pussy', 'asshole', 'faggot', 'hitler', 'porn']
  loop
    if position(w in flat) > 0 then return 'nickname_blocked'; end if;
  end loop;
  return null;
end $$;

-- ---------------------------------------------------------------- table
create table if not exists public.kodhane_profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  nickname   text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.kodhane_profiles add column if not exists hidden boolean not null default false;
alter table public.kodhane_profiles add column if not exists hidden_reason text;
comment on table public.kodhane_profiles is
  'Kodhane leaderboard opt-in: one public nickname per auth user. RLS own-row only; others see nicknames only via kodhane_leaderboard(). hidden/hidden_reason are admin-only.';

create unique index if not exists kodhane_profiles_nick_key_uniq on public.kodhane_profiles (public.kodhane_nick_key(nickname));

create or replace function public.kodhane_profiles_before_write()
returns trigger language plpgsql
security definer set search_path = ''
as $$
declare p text;
begin
  if tg_op = 'INSERT' or new.nickname is distinct from old.nickname then
    new.nickname := public.kodhane_nick_normalize(new.nickname);
    p := public.kodhane_nick_problem(new.nickname);
    if p is not null then
      raise exception using errcode = '23514', message = p;
    end if;
  end if;
  if tg_op = 'INSERT' then
    new.created_at := now();
  else
    new.created_at := old.created_at;
    new.user_id := old.user_id;
    -- choosing a genuinely new nickname lifts an admin hide
    if public.kodhane_nick_key(new.nickname) is distinct from public.kodhane_nick_key(old.nickname) then
      new.hidden := false;
      new.hidden_reason := null;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists kodhane_profiles_before_write on public.kodhane_profiles;
create trigger kodhane_profiles_before_write before insert or update on public.kodhane_profiles
  for each row execute function public.kodhane_profiles_before_write();

alter table public.kodhane_profiles enable row level security;

-- Players: read own row (without hidden_reason), write only user_id + nickname. hidden/hidden_reason: admin only.
revoke all on table public.kodhane_profiles from public;
revoke all on table public.kodhane_profiles from anon;
revoke all on table public.kodhane_profiles from authenticated;
grant select (user_id, nickname, hidden, created_at, updated_at) on table public.kodhane_profiles to authenticated;
grant insert (user_id, nickname) on table public.kodhane_profiles to authenticated;
grant update (user_id, nickname) on table public.kodhane_profiles to authenticated;  -- user_id needed by PostgREST upsert; WITH CHECK pins it to auth.uid()

drop policy if exists "kodhane_profiles_select_own" on public.kodhane_profiles;
drop policy if exists "kodhane_profiles_insert_own" on public.kodhane_profiles;
drop policy if exists "kodhane_profiles_update_own" on public.kodhane_profiles;
create policy "kodhane_profiles_select_own" on public.kodhane_profiles
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "kodhane_profiles_insert_own" on public.kodhane_profiles
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "kodhane_profiles_update_own" on public.kodhane_profiles
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------- score plausibility (heuristic, generous) — v4 for game v4.1
-- true = the save's totalEarned could have been earned honestly. Rules (documented in supabase-infra-status.md):
--  A) structure (exact game math):
--     runEarned <= cycleEarned (since last Halka Arz) <= totalEarned;
--     cycle: earlier rounds (cycle - run) < (shares + cycleRounds)^2 * 1e8, cycleRounds <= shares, cycleRounds <= prestigeCount,
--            shares <= sqrt(cycleRounds * earlierRounds / 1e8)  (Cauchy-Schwarz on g_i <= sqrt(run_i / 1e8));
--     Halka Arz: no IPO -> total == cycle and cycleRounds == prestigeCount; else prestigeCount >= cycleRounds + 3 * ipoCount,
--            ipoSharesEarned >= ipoCount and
--            game v4.1: Borsa Payı by the highest stage reached in the cycle -> ipoSharesEarned <= ipoCount * max(stagePays);
--            v4 saves (cube-root formula) with more pays stay valid only if earlier cycles (total - cycle) are large enough
--            for them: total - cycle >= ipoCount * ((ipoSharesEarned - ipoCount) / ipoCount)^3 * threshold.
--     stagePays max / threshold mirror game.js CFG.halkaArz (update both together).
--  B) time: totalEarned <= 10 * E * R, E = seconds since the save's start (not before 2026-09-27 launch, device-clock tolerant,
--     +1 h grace), R = max income per second any honest player could have with budget totalEarned: every employee type
--     (8 + the 3 new ones once totalEarned >= their stage threshold 1e15/1e19/1e23) at the max count affordable with the
--     WHOLE budget, all upgrade multipliers, 8 stages, 200 achievements, x32 for boost/offers/events/tasks, clicks, floor.
--     After a Halka Arz (tree possible): cost growth 1.14, share bonus 0.125/share with the largest share count any earlier
--     round could have had (sqrt(prestigeCount * total / 1e8)), İyi Referans x1.5, x64 extras, clicks x2 and Akış Hâli x10,
--     and (v4.1) the unspent Borsa Payı bonus x(1 + 0.01 * min(ipoSharesEarned, 50)) (unspent <= earned). Customer-sector cards
--     (v4.1) pay seconds of production like the old event cards and are inside the x32/x64 extras.
create or replace function public.kodhane_score_plausible(d jsonb, p_now timestamptz default now())
returns boolean language plpgsql stable parallel safe
set search_path = ''
as $$
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
end $$;
comment on function public.kodhane_score_plausible(jsonb, timestamptz) is
  'Kodhane leaderboard heuristic (v4, game v4.1: stage-based Borsa Payı, unspent bonus, sectors): false if a save''s totalEarned is implausible (see supabase-infra-status.md). Generous by design.';

-- ---------------------------------------------------------------- Açık Ofis score plausibility (v5, game Açık Ofis v2)
-- true = an Açık Ofis save's totalEarned could have been earned honestly. Generous by design (documented in
-- supabase-infra-status.md). Numbers mirror src/logic/config.js of thejackaltr/kodhane-acik-ofis (update both together):
--  A) structure: totalEarned a number >= 0; money <= totalEarned (+1); stage 0..2; Butik Stüdyo needs totalEarned >= 3000,
--     Ajans >= 200000 (unlockEarned); at most 200 staff.
--  B) time: totalEarned <= 2 * E * R (honest sims: >= 350x headroom, see ao_honest_gen.mjs). E = seconds since the save's start (not before 2026-09-27, +1 h grace, device-clock
--     tolerant like Kodhane). R = max income per second with budget totalEarned: every hireable type at the max count the
--     WHOLE budget could buy (cost growth 1.15), work units valued kod + 1.35 * tasarim, x all upgrades (1.581), x the best
--     desk spot (1.48: kahve + bitki + PM), x3 buffs, x3 project pay (offer roll, Tasarımcı + sunucu, event pay cards),
--     x2 event cash, x2.25 (Ajans), plus 20 laptop taps/s (x2 keyboard) and a 100 TL/s floor.
create or replace function public.acik_ofis_score_plausible(d jsonb, p_now timestamptz default now())
returns boolean language plpgsql stable parallel safe
set search_path = ''
as $$
declare
  t float8; m float8; st float8; ls float8; nowms float8; launch float8; e float8; stg int;
  base float8 := 1.54;  -- the founder (kod 1 + 0.4 tasarim * 1.35)
  n float8; r float8; g record;
  mult constant float8 := 1.581 * 1.48 * 3 * 3 * 2 * 2.25;
begin
  if d is null or jsonb_typeof(d -> 'totalEarned') is distinct from 'number' then return false; end if;
  if (d ->> 'totalEarned')::numeric < 0 or (d ->> 'totalEarned')::numeric > 1e300 then return false; end if;
  t := (d ->> 'totalEarned')::float8;
  if jsonb_typeof(d -> 'money') = 'number' then
    if abs((d ->> 'money')::numeric) > 1e300 then return false; end if;
    m := (d ->> 'money')::float8;
    if m > t + 1 then return false; end if;
  end if;
  stg := 0;
  if jsonb_typeof(d -> 'stage') = 'number' then
    if (d ->> 'stage')::numeric < 0 or (d ->> 'stage')::numeric > 2 then return false; end if;
    stg := floor((d ->> 'stage')::numeric)::int;
  end if;
  if stg >= 1 and t < 3000 then return false; end if;
  if stg >= 2 and t < 200000 then return false; end if;
  if jsonb_typeof(d -> 'staff') = 'array' and jsonb_array_length(d -> 'staff') > 200 then return false; end if;

  nowms := extract(epoch from p_now) * 1000;
  launch := extract(epoch from timestamptz '2026-09-27 00:00:00+00') * 1000;
  st := null; ls := null;
  if jsonb_typeof(d -> 'startedAt') = 'number' then st := least(greatest((d ->> 'startedAt')::numeric, -1e15), 1e15)::float8; end if;
  if jsonb_typeof(d -> 'lastSaved') = 'number' then ls := least(greatest((d ->> 'lastSaved')::numeric, -1e15), 1e15)::float8; end if;
  if st is null or st < launch then st := launch; end if;
  e := greatest(nowms - st, coalesce(ls - st, 0), 0);
  e := least(e, greatest(nowms - launch, 0)) / 1000.0 + 3600;

  -- (cost, work value per second) per hireable type = config.js STAFF
  for g in select * from (values (40::float8, 1.405::float8), (450, 5.58), (1100, 10.45), (3800, 18.7), (30000, 76.2), (8000, 4.7)) v(c, w) loop
    n := least(200, floor(ln(t * 0.15 / g.c + 1) / ln(1.15)));
    base := base + g.w * n;
  end loop;
  r := base * mult + 20 * 2 * (2 + 0.04 * base * 1.581 * 1.48 * 3) * 1.35 * 3 * 2.25 + 100;
  return t <= 2 * e * r;
end $$;
comment on function public.acik_ofis_score_plausible(jsonb, timestamptz) is
  'Açık Ofis leaderboard heuristic (v5, game v2): false if a save''s totalEarned is implausible (see supabase-infra-status.md). Generous by design.';

-- ---------------------------------------------------------------- anonymous event counter (news popup)
-- Per-day aggregate only: (day in Europe/Istanbul, event name, count). No user id, IP or any personal data.
-- Whitelisted event names; callable by anon + authenticated through the SECURITY DEFINER function only.
create table if not exists public.kodhane_event_counts (
  day   date   not null,
  event text   not null,
  count bigint not null default 0,
  primary key (day, event)
);
comment on table public.kodhane_event_counts is 'Kodhane anonymous per-day counters (news popups, Açık Ofis signups from Kodhane). No personal data. Written only via kodhane_count_event().';
alter table public.kodhane_event_counts enable row level security;
revoke all on table public.kodhane_event_counts from public;
revoke all on table public.kodhane_event_counts from anon;
revoke all on table public.kodhane_event_counts from authenticated;

create or replace function public.kodhane_count_event(p_event text)
returns boolean language plpgsql volatile
security definer set search_path = ''
as $$
begin
  if p_event is null or p_event not in ('news_leaderboard_shown', 'news_leaderboard_click',
                                        'news_acikofis_shown', 'news_acikofis_click', 'acikofis_cloud_signup_kodhane',
                                        'acikofis_stage_0', 'acikofis_stage_1', 'acikofis_stage_2') then
    return false;
  end if;
  insert into public.kodhane_event_counts as c (day, event, count)
  values ((now() at time zone 'Europe/Istanbul')::date, p_event, 1)
  on conflict (day, event) do update set count = c.count + 1;
  return true;
end $$;
comment on function public.kodhane_count_event(text) is
  'Anonymous whitelisted per-day counter (news_leaderboard_shown/_click, news_acikofis_shown/_click, acikofis_cloud_signup_kodhane, acikofis_stage_0..2 = Açık Ofis first delivery / reached Butik Stüdyo / Ajans). Returns false for unknown names.';
revoke all on function public.kodhane_count_event(text) from public;
grant execute on function public.kodhane_count_event(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------- leaderboard RPC
-- p_game keeps lists apart: 'kodhane' (kodhane_saves) or 'acik_ofis' (acik_ofis_saves, v5); any other game -> empty list.
-- The nickname profile (and its admin hide) is shared: one nickname per account, shown on both lists.
-- Top p_limit (1..100, default 50) listed players (nickname, not hidden, valid + plausible cloud save), plus the
-- caller's own row: appended if outside the top list, or flagged with status 'pending' (score being checked:
-- invalid/implausible) / 'hidden' (admin-hidden) with rank/score null. Never returns user_id/email.
drop function if exists public.kodhane_leaderboard(int);
drop function if exists public.kodhane_leaderboard(int, text);
create function public.kodhane_leaderboard(p_limit int default 50, p_game text default 'kodhane')
returns table (rank bigint, nickname text, score numeric, stage int, is_me boolean, status text)
language sql stable
security definer set search_path = ''
as $$
  with me as (
    select (select auth.uid()) as uid
  ), src as (
    select p.user_id, p.nickname, p.created_at, p.hidden, s.data, 'kodhane'::text as g,
           case when jsonb_typeof(s.data -> 'totalEarned') = 'number' then (s.data ->> 'totalEarned')::numeric end as n
    from public.kodhane_profiles p
    join public.kodhane_saves s on s.user_id = p.user_id
    where lower(btrim(coalesce(p_game, 'kodhane'))) = 'kodhane'
    union all
    select p.user_id, p.nickname, p.created_at, p.hidden, s.data, 'acik_ofis'::text as g,
           case when jsonb_typeof(s.data -> 'totalEarned') = 'number' then (s.data ->> 'totalEarned')::numeric end as n
    from public.kodhane_profiles p
    join public.acik_ofis_saves s on s.user_id = p.user_id
    where lower(btrim(coalesce(p_game, 'kodhane'))) = 'acik_ofis'
  ), judged as (
    select user_id, nickname, created_at, n,
           case when hidden then 'hidden'
                when n is null or n < 0 or n > 1.7976931348623157e308 then 'pending'
                when (case when g = 'acik_ofis' then not public.acik_ofis_score_plausible(data)
                           else not public.kodhane_score_plausible(data) end) then 'pending'
                else 'ok' end as status,
           case when jsonb_typeof(data -> 'stage') = 'number'
                then least(99, greatest(0, floor((data ->> 'stage')::numeric)))::int end as stage
    from src
  ), ranked as (
    -- score stays numeric (never int/bigint; not float8 either: PostgREST prints float8 with 15 digits)
    select user_id, nickname, n as score, stage,
           rank() over (order by n desc) as rank,
           row_number() over (order by n desc, created_at, nickname) as rn
    from judged where status = 'ok'
  ), out as (
    select r.rn as k, r.rank, r.nickname, r.score, r.stage,
           coalesce(r.user_id = (select uid from me), false) as is_me, 'ok'::text as status
    from ranked r
    where r.rn <= least(100, greatest(1, coalesce(p_limit, 50))) or r.user_id = (select uid from me)
    union all
    select 9223372036854775807, null, j.nickname, null, null, true, j.status
    from judged j
    where j.status <> 'ok' and j.user_id = (select uid from me)
  )
  select o.rank, o.nickname, o.score, o.stage, o.is_me, o.status from out o order by o.k
$$;
comment on function public.kodhane_leaderboard(int, text) is
  'Kodhane + Açık Ofis leaderboard (p_game kodhane|acik_ofis): rank, nickname, score (numeric all-time totalEarned), stage, is_me, status (ok|pending|hidden, own row only). No user ids.';

revoke all on function public.kodhane_leaderboard(int, text) from public;
grant execute on function public.kodhane_leaderboard(int, text) to anon, authenticated, service_role;

revoke all on function public.kodhane_nick_key(text) from public, anon;
grant execute on function public.kodhane_nick_key(text) to authenticated, service_role;
revoke all on function public.kodhane_nick_normalize(text) from public, anon;
grant execute on function public.kodhane_nick_normalize(text) to authenticated, service_role;
revoke all on function public.kodhane_nick_problem(text) from public, anon;
grant execute on function public.kodhane_nick_problem(text) to authenticated, service_role;
revoke all on function public.kodhane_score_plausible(jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.kodhane_score_plausible(jsonb, timestamptz) to service_role;
revoke all on function public.acik_ofis_score_plausible(jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.acik_ofis_score_plausible(jsonb, timestamptz) to service_role;
revoke all on function public.kodhane_profiles_before_write() from public, anon, authenticated;

commit;
notify pgrst, 'reload schema';
