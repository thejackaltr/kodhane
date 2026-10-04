-- =====================================================================================================
-- Kodhane v2.2: save safety — KODHANE ONLY (DRAFT, NOT APPLIED ANYWHERE REAL)
-- Target: the Kodhane Supabase (today the shared supabase.teserix.com; after the split: Kodhane's own DB). Unchanged file
-- for both. Touches ONLY kodhane_* objects. Independent of the Açık Ofis file
-- (20260928160100_v2_2_acik_ofis_save_safety.sql): either can be applied alone, in any order, or both.
-- Requires Kodhane's own base objects: kodhane-cloud/schema.sql (kodhane_saves) + leaderboard.sql (kodhane_profiles,
-- kodhane_score_plausible). Fixes "Kaydı sıfırla" wiping the all-time score (the client DELETEs the row). Adds:
--   1. kodhane_saves.best_score (numeric, never decreases; = GREATEST(old, vetted data->'totalEarned')),
--      kodhane_saves.best_stage (int 0..99, never decreases; same vetting), backfilled from the current save
--      (vetted = only if kodhane_score_plausible() accepts the save now; stage must be reachable with totalEarned).
--   2. public.kodhane_save_backups + public.kodhane_game_config (retention, cap, revision mode) + kodhane_cleanup_save_backups().
--      This file never touches pg_cron (optional: supabase/ops/20260928160000_v2_2_kodhane_schedule_cleanup.sql).
--   3. kodhane_saves.revision: stale writes rejected with SQLSTATE PT409 (-> HTTP 409). Rule: revision < server -> stale.
--      A write that does not advance the revision (pre-v2.2 clients never send one) is accepted only while the row never
--      saw an explicit revision (strict_revision = false) AND kodhane_game_config.revision_mode = 'lenient' (default) AND
--      it does not lower totalEarned (else stale_write); the server then assigns revision + 1. 'strict' requires a higher
--      revision always. A higher revision is accepted and makes the row strict (strict_revision = true).
--   4. RPCs (no p_game): kodhane_reset_save(), kodhane_restore_save(p_backup_id), kodhane_list_save_backups().
--   5. RLS: own row select/insert/update only; no delete policy, no DELETE grant; backups: own + not expired, read only.
--   6. kodhane_leaderboard(p_limit, p_game) v6 (same signature/columns): Kodhane list from best_score/best_stage.
--      p_game = 'acik_ofis' is a COMPATIBILITY path for today's shared DB only (Açık Ofis clients <= v2.2 call it,
--      nicknames from kodhane_profiles): dynamic SQL, only if public.acik_ofis_saves + acik_ofis_score_plausible exist
--      (v6 rules if the Açık Ofis v2.2 file is applied, else the v5 rules); otherwise an empty list, never an error.
--      After the split Açık Ofis uses its own acik_ofis_leaderboard(p_limit) (Açık Ofis file).
-- kodhane_leaderboard is defined HERE from v2.2 on; kodhane-cloud/leaderboard.sql (v6) no longer defines it, so
-- re-running that file cannot bring v5 back. Never run kodhane-cloud/leaderboard.v5.sql (or older) after this.
-- Conventions: one transaction, objects owned by postgres, idempotent (safe to run twice), search_path = '' +
-- schema-qualified names, explicit revokes (Supabase default privileges), notify pgrst at the end.
-- Rollback: supabase/rollback/20260928160000_v2_2_kodhane_save_safety.rollback.sql
-- =====================================================================================================
begin;
set local role postgres;

do $pre$
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('public.kodhane_profiles') is null
     or to_regprocedure('public.kodhane_score_plausible(jsonb,timestamptz)') is null then
    raise exception 'Kodhane v2.2: public.kodhane_saves, public.kodhane_profiles and public.kodhane_score_plausible(jsonb, timestamptz) are required (apply kodhane-cloud/schema.sql + leaderboard.sql first)';
  end if;
end $pre$;

-- Triggers are recreated at the end; dropping them first keeps the backfill below trigger-free on re-runs.
drop trigger if exists kodhane_saves_before_write on public.kodhane_saves;
drop trigger if exists kodhane_saves_before_delete on public.kodhane_saves;

-- ---------------------------------------------------------------- config
create table if not exists public.kodhane_game_config (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now()
);
comment on table public.kodhane_game_config is 'Server-side knobs for the Kodhane save functions (v2.2). Admin only (no client access).';
alter table public.kodhane_game_config enable row level security;
revoke all on table public.kodhane_game_config from public, anon, authenticated;
grant select, insert, update, delete on table public.kodhane_game_config to service_role;

insert into public.kodhane_game_config (key, value, description) values
  ('backup_retention_days', '30'::jsonb,        'kodhane_save_backups older than this many days are hidden, not restorable, and deleted by kodhane_cleanup_save_backups()'),
  ('backup_max_per_user',   '50'::jsonb,        'at most this many backups per player (oldest trimmed by kodhane_reset_save/kodhane_restore_save)'),
  ('revision_mode',         '"lenient"'::jsonb, 'lenient: writes without a new revision are accepted unless they lower totalEarned; strict: revision must increase')
on conflict (key) do nothing;
-- first run only: the exact kodhane_leaderboard(int, text) definition before this migration (v5, or the Açık Ofis
-- v2.2 shim, or none); the rollback restores exactly that (or drops the function if there was none)
insert into public.kodhane_game_config (key, value, description)
select 'v22_pre.kodhane_leaderboard',
       case when f.oid is null then jsonb_build_object('exists', false)
            else jsonb_build_object('exists', true, 'def', pg_get_functiondef(f.oid), 'comment', obj_description(f.oid, 'pg_proc')) end,
       'set once by the v2.2 migration: previous kodhane_leaderboard definition (used by the rollback)'
  from (select to_regprocedure('public.kodhane_leaderboard(integer,text)')::oid as oid) f
on conflict (key) do nothing;

create or replace function public.kodhane_config_int(p_key text, p_default int)
returns int language plpgsql stable security definer set search_path = ''
as $$
declare v jsonb;
begin
  select c.value into v from public.kodhane_game_config c where c.key = p_key;
  if v is null or jsonb_typeof(v) <> 'number' then return p_default; end if;
  return floor((v #>> '{}')::numeric)::int;
exception when others then return p_default;
end $$;

create or replace function public.kodhane_config_text(p_key text, p_default text)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare v jsonb;
begin
  select c.value into v from public.kodhane_game_config c where c.key = p_key;
  if v is null or jsonb_typeof(v) <> 'string' then return p_default; end if;
  return v #>> '{}';
end $$;

-- retention as an interval, clamped to 1..3650 days
create or replace function public.kodhane_save_backup_retention()
returns interval language sql stable security definer set search_path = ''
as $$ select make_interval(days => least(3650, greatest(1, public.kodhane_config_int('backup_retention_days', 30)))) $$;

-- ---------------------------------------------------------------- score / stage helpers
-- raw score = data->'totalEarned' if it is a JSON number in [0, max float8], else 0 (numeric end to end)
create or replace function public.kodhane_save_score(d jsonb)
returns numeric language sql immutable parallel safe set search_path = ''
as $$
  select case when jsonb_typeof(d -> 'totalEarned') = 'number' then
           case when (d ->> 'totalEarned')::numeric between 0 and 1.7976931348623157e308
                then (d ->> 'totalEarned')::numeric else 0::numeric end
         else 0::numeric end
$$;

-- score that may enter best_score: raw score, only if the save is plausible now (kodhane-cloud/leaderboard.sql rule), else 0.
-- Without this, a player could write an implausible save ('pending'), then reset, and keep the inflated best_score.
create or replace function public.kodhane_save_vetted_score(d jsonb)
returns numeric language plpgsql stable security definer set search_path = ''
as $$
declare s numeric := public.kodhane_save_score(d);
begin
  if s > 0 and coalesce(public.kodhane_score_plausible(d, now()), false) then return s; end if;
  return 0;
end $$;

-- raw stage = data->'stage' clamped to 0..99 exactly like the leaderboard always did; not a JSON number -> 0
create or replace function public.kodhane_save_stage(d jsonb)
returns int language sql immutable parallel safe set search_path = ''
as $$
  select case when jsonb_typeof(d -> 'stage') = 'number'
              then least(99, greatest(0, floor((d ->> 'stage')::numeric)))::int else 0 end
$$;

-- raw stage, but 0 if the save could not have reached it: stage i needs runEarned >= STAGES[i].at at some point and
-- totalEarned >= runEarned. Thresholds mirror idle-ajans game.js STAGES (9 stages 0..8), update both together.
create or replace function public.kodhane_save_stage_checked(d jsonb)
returns int language plpgsql immutable set search_path = ''
as $$
declare st int := public.kodhane_save_stage(d); s numeric := public.kodhane_save_score(d);
begin
  if st = 0 or s <= 0 then return 0; end if;
  if st > 8 or s < ('{0,1e3,5e4,1e6,5e7,2.5e9,1e15,1e19,1e23}'::numeric[])[st + 1] then return 0; end if;
  return st;
end $$;

-- stage that may enter best_stage (same rule as best_score): checked stage, only if the save is plausible now, else 0
create or replace function public.kodhane_save_vetted_stage(d jsonb)
returns int language plpgsql stable security definer set search_path = ''
as $$
declare st int := public.kodhane_save_stage_checked(d);
begin
  if st > 0 and coalesce(public.kodhane_score_plausible(d, now()), false) then return st; end if;
  return 0;
end $$;

-- the cleared payload written by kodhane_reset_save (idle-ajans/game.js newState + deserialize): money, run/total/cycle
-- earnings, employees (gens), upgrades, achievements, Yatırım Turu (shares, prestigeCount, cycleRounds), Halka Arz/Borsa
-- (ipoShares, ipoSharesEarned, ipoCount, tree), stage/stageBest/cycleStage, reputation, daily (streak) and all run stats
-- are reset; only the 'newsSeen' UI flags are kept. Nickname (kodhane_profiles), user_id, best_score, best_stage are
-- outside 'data' and never touched. Sound/vibration live in a separate localStorage key (client only).
create or replace function public.kodhane_save_reset_payload(p_old jsonb, p_now_ms numeric)
returns jsonb language sql immutable set search_path = ''
as $$
  select jsonb_build_object(
    'version', case when jsonb_typeof(p_old -> 'version') = 'number' then p_old -> 'version' else to_jsonb(4) end,
    'startedAt', p_now_ms, 'lastSaved', p_now_ms, 'resetAt', p_now_ms,
    'money', 0, 'runEarned', 0, 'totalEarned', 0, 'cycleEarned', 0,
    'clicks', 0, 'clickEarned', 0, 'playTime', 0, 'eventsClicked', 0, 'offlineEarned', 0,
    'gens', '{}'::jsonb, 'upgrades', '[]'::jsonb, 'achievements', '[]'::jsonb,
    'shares', 0, 'prestigeCount', 0, 'cycleRounds', 0,
    'ipoShares', 0, 'ipoSharesEarned', 0, 'ipoCount', 0, 'tree', '[]'::jsonb,
    'stage', 0, 'stageBest', 0, 'cycleStage', 0,
    'reputation', 0, 'boostLeft', 0, 'buffs', '[]'::jsonb,
    'critClicks', 0, 'eventsResolved', 0, 'logoAccepted', 0, 'revisions', 0, 'meetings', 0, 'serverCrashes', 0,
    'noMeetingSec', 0,
    'daily', jsonb_build_object('date', null, 'tasks', '[]'::jsonb, 'streak', 0, 'best', 0, 'lastComplete', null,
                                'allDone', false, 'daysCompleted', 0),
    'newsSeen', case when jsonb_typeof(p_old -> 'newsSeen') = 'array' then p_old -> 'newsSeen' else '[]'::jsonb end,
    'newsPending', '[]'::jsonb,
    'sectorCool', '{}'::jsonb, 'followUps', jsonb_build_object('kafe', 0, 'emlak', 0), 'pendingPay', '[]'::jsonb)
$$;

-- save_version as the client sends it (data.version || 2)
create or replace function public.kodhane_save_version_of(d jsonb)
returns int language sql immutable set search_path = ''
as $$
  select coalesce(case when jsonb_typeof(d -> 'version') = 'number'
                       then least(1000000, greatest(0, floor((d ->> 'version')::numeric)))::int end, 2)
$$;

-- ---------------------------------------------------------------- columns + backfill
alter table public.kodhane_saves
  add column if not exists best_score numeric not null default 0 constraint kodhane_saves_best_score_nonneg check (best_score >= 0),
  add column if not exists revision bigint not null default 0 constraint kodhane_saves_revision_nonneg check (revision >= 0),
  add column if not exists strict_revision boolean not null default false,
  add column if not exists best_stage int not null default 0 constraint kodhane_saves_best_stage_range check (best_stage between 0 and 99);
comment on column public.kodhane_saves.best_score is 'All-time best data.totalEarned (plausible saves only). Never decreases; survives reset. Leaderboard score.';
comment on column public.kodhane_saves.best_stage is 'All-time best data.stage (0..99, plausible + reachable only). Never decreases; survives reset. Leaderboard stage.';
comment on column public.kodhane_saves.revision is
  'Optimistic concurrency counter; the client sends last seen revision + 1. Lower than the server: always stale (PT409 stale_revision). Equal, or not sent (pre-v2.2 clients): stale (PT409 stale_revision) on a strict row (strict_revision) or with revision_mode = strict; on a lenient row accepted if totalEarned does not drop (the server stores revision + 1, row stays lenient), otherwise PT409 stale_write. Higher: accepted, and the row becomes strict. (Unrelated to data.revisions, a game stat.)';
comment on column public.kodhane_saves.strict_revision is 'Set by the server once the row was written with an explicit, increasing revision (v2.2 client or kodhane_reset_save/kodhane_restore_save). From then on a write that does not advance the revision is stale, even in lenient mode.';

-- backfill (idempotent, only raises): current save if plausible now, else 0 (today's 'pending' players stay off the list)
update public.kodhane_saves s set best_score = greatest(s.best_score, public.kodhane_save_vetted_score(s.data))
 where public.kodhane_save_vetted_score(s.data) > s.best_score;
update public.kodhane_saves s set best_stage = greatest(s.best_stage, public.kodhane_save_vetted_stage(s.data))
 where public.kodhane_save_vetted_stage(s.data) > s.best_stage;

-- ---------------------------------------------------------------- backups
create table if not exists public.kodhane_save_backups (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  revision   bigint not null,
  payload    jsonb not null,
  best_score numeric not null default 0,
  best_stage int not null default 0,
  reason     text not null constraint kodhane_save_backups_reason_chk check (reason in ('reset', 'restore', 'delete', 'manual')),
  created_at timestamptz not null default now()
);
comment on table public.kodhane_save_backups is
  'Snapshots of kodhane_saves rows taken by kodhane_reset_save/kodhane_restore_save (and admin deletes). Players read their own non-expired rows; nobody writes directly.';
create index if not exists kodhane_save_backups_user_created_idx on public.kodhane_save_backups (user_id, created_at desc);
create index if not exists kodhane_save_backups_created_idx on public.kodhane_save_backups (created_at);
alter table public.kodhane_save_backups enable row level security;
revoke all on table public.kodhane_save_backups from public, anon, authenticated;
grant select on table public.kodhane_save_backups to authenticated;
grant select, insert, update, delete on table public.kodhane_save_backups to service_role;
drop policy if exists "kodhane_save_backups_select_own" on public.kodhane_save_backups;
create policy "kodhane_save_backups_select_own" on public.kodhane_save_backups
  for select to authenticated
  using ((select auth.uid()) = user_id and created_at > now() - (select public.kodhane_save_backup_retention()));

-- expired + over-cap backups of one player (called inside reset/restore, so no cron is strictly needed per player)
create or replace function public.kodhane_save_backups_trim(p_uid uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare cap int := least(1000, greatest(1, public.kodhane_config_int('backup_max_per_user', 50)));
begin
  delete from public.kodhane_save_backups b where b.user_id = p_uid and b.created_at <= now() - public.kodhane_save_backup_retention();
  delete from public.kodhane_save_backups b
   where b.id in (select x.id from public.kodhane_save_backups x where x.user_id = p_uid
                  order by x.created_at desc, x.id desc offset cap);
end $$;

-- global cleanup (optional pg_cron job / admin): deletes every backup older than backup_retention_days; returns the count
create or replace function public.kodhane_cleanup_save_backups()
returns integer language plpgsql volatile security definer set search_path = ''
as $$
declare n integer;
begin
  delete from public.kodhane_save_backups b where b.created_at <= now() - public.kodhane_save_backup_retention();
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- write triggers
create or replace function public.kodhane_save_before_write()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  vetted numeric := public.kodhane_save_vetted_score(new.data);
  vetted_stage int := public.kodhane_save_vetted_stage(new.data);
  prev_best numeric; prev_stage int;
begin
  if tg_op = 'INSERT' then
    new.revision := greatest(coalesce(new.revision, 0), 0);
    new.strict_revision := new.revision > 0;   -- an explicit first revision = v2.2 client
    -- a (re)created row starts from the best score/stage kept in its backups (survives admin deletes)
    select coalesce(max(b.best_score), 0), coalesce(max(b.best_stage), 0) into prev_best, prev_stage
      from public.kodhane_save_backups b where b.user_id = new.user_id;
    new.best_score := greatest(vetted, prev_best);
    new.best_stage := least(99, greatest(vetted_stage, prev_stage));
    return new;
  end if;

  new.user_id := old.user_id;
  new.revision := coalesce(new.revision, old.revision);
  if new.revision < old.revision then
    raise exception using errcode = 'PT409', message = 'stale_revision',
      detail = format('sent revision %s, server revision %s', new.revision, old.revision),
      hint = 'Pull the save again and send revision = server revision + 1.';
  elsif new.revision = old.revision then
    -- the client did not advance the revision: a pre-v2.2 client (never sends it) or a stale v2.2 write
    if old.strict_revision or public.kodhane_config_text('revision_mode', 'lenient') = 'strict' then
      raise exception using errcode = 'PT409', message = 'stale_revision',
        detail = format('sent revision %s, server revision %s', new.revision, old.revision),
        hint = 'Send revision = server revision + 1.';
    end if;
    if public.kodhane_save_score(new.data) < public.kodhane_save_score(old.data) then
      -- the bug: a locally reset (empty) save overwriting real progress. Resets must go through kodhane_reset_save().
      raise exception using errcode = 'PT409', message = 'stale_write',
        detail = format('totalEarned would drop from %s to %s without a new revision', public.kodhane_save_score(old.data), public.kodhane_save_score(new.data)),
        hint = 'Use kodhane_reset_save() to start over; pull the save before writing.';
    end if;
    new.revision := old.revision + 1;
    new.strict_revision := false;
  else
    new.strict_revision := true;   -- explicit increasing revision: this row now follows the v2.2 protocol
  end if;
  new.best_score := greatest(old.best_score, vetted);        -- never decreases (client cannot write it)
  new.best_stage := greatest(old.best_stage, vetted_stage);  -- same rule
  return new;
end $$;

-- clients cannot delete (no policy, no grant); an admin/service_role delete still leaves a backup behind.
-- pg_trigger_depth() > 1 = cascaded from auth.users (account deletion): no backup, the account's backups go too.
create or replace function public.kodhane_save_before_delete()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if pg_trigger_depth() = 1 then
    insert into public.kodhane_save_backups (user_id, revision, payload, best_score, best_stage, reason)
    values (old.user_id, old.revision, old.data, old.best_score, old.best_stage, 'delete');
  end if;
  return old;
end $$;

create trigger kodhane_saves_before_write before insert or update on public.kodhane_saves
  for each row execute function public.kodhane_save_before_write();
create trigger kodhane_saves_before_delete before delete on public.kodhane_saves
  for each row execute function public.kodhane_save_before_delete();

-- ---------------------------------------------------------------- RLS + grants on kodhane_saves
-- select/insert/update own row only. No delete policy + no DELETE grant: the old "Kaydı sıfırla" DELETE
-- (idle-ajans/cloud.js beforeReset) now fails with 42501 and must be replaced by rpc/kodhane_reset_save.
drop policy if exists "kodhane_saves_delete_own" on public.kodhane_saves;
-- column grants: clients may write user_id, data, save_version, updated_at, revision; never best_score/best_stage/strict_revision.
revoke all on table public.kodhane_saves from public, anon, authenticated;
grant select on table public.kodhane_saves to authenticated;
grant insert (user_id, data, save_version, updated_at, revision) on table public.kodhane_saves to authenticated;
grant update (user_id, data, save_version, updated_at, revision) on table public.kodhane_saves to authenticated;

-- ---------------------------------------------------------------- RPCs
-- kodhane_reset_save: one transaction: backup current row -> clear progress -> revision + 1. best_score, best_stage,
-- user_id and the nickname are kept. Returns {revision, backup_id, best_score, best_stage}. No row -> revision 0, backup_id null.
create or replace function public.kodhane_reset_save()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  v_data jsonb; v_rev bigint; v_best numeric; v_stage int; v_bid uuid;
  v_now_ms numeric := floor(extract(epoch from clock_timestamp()) * 1000);
begin
  if uid is null then raise exception using errcode = '42501', message = 'not_authenticated'; end if;
  select s.data, s.revision, s.best_score, s.best_stage into v_data, v_rev, v_best, v_stage
    from public.kodhane_saves s where s.user_id = uid for update;
  if not found then
    return jsonb_build_object('revision', 0, 'backup_id', null, 'best_score', 0, 'best_stage', 0);
  end if;
  insert into public.kodhane_save_backups (user_id, revision, payload, best_score, best_stage, reason)
  values (uid, v_rev, v_data, v_best, v_stage, 'reset') returning id into v_bid;
  update public.kodhane_saves s set data = public.kodhane_save_reset_payload(v_data, v_now_ms), revision = v_rev + 1, updated_at = now()
   where s.user_id = uid returning s.best_score, s.best_stage into v_best, v_stage;
  perform public.kodhane_save_backups_trim(uid);
  return jsonb_build_object('revision', v_rev + 1, 'backup_id', v_bid, 'best_score', v_best, 'best_stage', v_stage);
end $$;

-- kodhane_restore_save: own, non-expired backup only (else PT404 backup_not_found -> HTTP 404). Backs up the current row
-- first (reason 'restore' -> the restore itself can be undone), writes the backup payload with revision + 1.
-- Used for the 10 s "Geri al" and the 30-day restore. Returns {revision, backup_id, restored_from, best_score, best_stage}.
create or replace function public.kodhane_restore_save(p_backup_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  b record;
  v_data jsonb; v_rev bigint; v_best numeric; v_stage int; v_bid uuid := null; v_new_rev bigint;
begin
  if uid is null then raise exception using errcode = '42501', message = 'not_authenticated'; end if;
  select x.id, x.revision, x.payload into b
    from public.kodhane_save_backups x
   where x.id = p_backup_id and x.user_id = uid and x.created_at > now() - public.kodhane_save_backup_retention();
  if not found then raise exception using errcode = 'PT404', message = 'backup_not_found'; end if;

  select s.data, s.revision, s.best_score, s.best_stage into v_data, v_rev, v_best, v_stage
    from public.kodhane_saves s where s.user_id = uid for update;
  if found then
    insert into public.kodhane_save_backups (user_id, revision, payload, best_score, best_stage, reason)
    values (uid, v_rev, v_data, v_best, v_stage, 'restore') returning id into v_bid;
    v_new_rev := v_rev + 1;
    update public.kodhane_saves s set data = b.payload, revision = v_new_rev, save_version = public.kodhane_save_version_of(b.payload), updated_at = now()
     where s.user_id = uid returning s.best_score, s.best_stage into v_best, v_stage;
  else
    v_new_rev := b.revision + 1;
    insert into public.kodhane_saves (user_id, data, save_version, revision, updated_at)
    values (uid, b.payload, public.kodhane_save_version_of(b.payload), v_new_rev, now()) returning best_score, best_stage into v_best, v_stage;
  end if;
  perform public.kodhane_save_backups_trim(uid);
  return jsonb_build_object('revision', v_new_rev, 'backup_id', v_bid, 'restored_from', b.id, 'best_score', v_best, 'best_stage', v_stage);
end $$;

-- kodhane_list_save_backups: the caller's non-expired backups (newest first) with score + stage inside each payload
drop function if exists public.kodhane_list_save_backups();
create function public.kodhane_list_save_backups()
returns table (id uuid, revision bigint, reason text, score numeric, best_score numeric, stage int, best_stage int,
               created_at timestamptz, expires_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select b.id, b.revision, b.reason, public.kodhane_save_score(b.payload), b.best_score,
         public.kodhane_save_stage(b.payload), b.best_stage, b.created_at, b.created_at + public.kodhane_save_backup_retention()
    from public.kodhane_save_backups b
   where b.user_id = (select auth.uid()) and b.created_at > now() - public.kodhane_save_backup_retention()
   order by b.created_at desc, b.id desc
$$;

-- ---------------------------------------------------------------- leaderboard v6 (same signature/columns as v5)
-- SINGLE SOURCE OF TRUTH for kodhane_leaderboard from v2.2 on (kodhane-cloud/leaderboard.sql points here).
-- Kodhane list: score = GREATEST(best_score, current totalEarned if valid + plausible now); best_score > 0 -> listed;
-- best_score = 0 -> the v5 rule (invalid/implausible current save -> own row 'pending').
-- stage = GREATEST(best_stage, current checked stage if the current save is plausible now) = all-time best stage
-- (v5 showed the current save's stage; an 'ok' row without a stage now shows 0 instead of null).
-- p_game = 'acik_ofis': compatibility path (see header), dynamic SQL so this file never depends on Açık Ofis objects.
create or replace function public.kodhane_leaderboard(p_limit int default 50, p_game text default 'kodhane')
returns table (rank bigint, nickname text, score numeric, stage int, is_me boolean, status text)
language plpgsql stable
security definer set search_path = ''
as $fn$
#variable_conflict use_column
declare
  g text := lower(btrim(coalesce(p_game, 'kodhane')));
  lim int := least(100, greatest(1, coalesce(p_limit, 50)));
  uid uuid := auth.uid();
  ao_v22 boolean;
begin
  if g = 'kodhane' then
    return query
    with src as materialized (
      select p.user_id, p.nickname, p.created_at, p.hidden, s.data, s.best_score, s.best_stage,
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
             greatest(best_stage, case when cur_ok then public.kodhane_save_stage_checked(data) else 0 end) as stage
      from vetted
    ), ranked as (
      -- score stays numeric (never int/bigint; not float8 either: PostgREST prints float8 with 15 digits)
      select user_id, nickname, n as score, stage,
             rank() over (order by n desc) as rank,
             row_number() over (order by n desc, created_at, nickname) as rn
      from judged where status = 'ok'
    ), out as (
      select r.rn as k, r.rank, r.nickname, r.score, r.stage, coalesce(r.user_id = uid, false) as is_me, 'ok'::text as status
      from ranked r
      where r.rn <= lim or r.user_id = uid
      union all
      select 9223372036854775807, null, j.nickname, null, null, true, j.status
      from judged j
      where j.status <> 'ok' and j.user_id = uid
    )
    select o.rank, o.nickname, o.score, o.stage, o.is_me, o.status from out o order by o.k;
    return;
  end if;

  if g <> 'acik_ofis' or to_regclass('public.acik_ofis_saves') is null
     or to_regprocedure('public.acik_ofis_score_plausible(jsonb,timestamptz)') is null then
    return;   -- unknown game / Açık Ofis not installed in this database: empty list, no error
  end if;
  select count(*) = 2 into ao_v22 from pg_catalog.pg_attribute a
   where a.attrelid = to_regclass('public.acik_ofis_saves') and a.attname in ('best_score', 'best_stage') and not a.attisdropped;
  return query execute format($q$
    with src as materialized (
      select p.user_id, p.nickname, p.created_at, p.hidden, s.data, %s as best_score, %s as best_stage,
             case when jsonb_typeof(s.data -> 'totalEarned') = 'number' then (s.data ->> 'totalEarned')::numeric end as n_cur
      from public.kodhane_profiles p
      join public.acik_ofis_saves s on s.user_id = p.user_id
    ), vetted as materialized (
      select src.*, (n_cur is not null and n_cur >= 0 and n_cur <= 1.7976931348623157e308
                     and public.acik_ofis_score_plausible(data)) as cur_ok
      from src
    ), judged as (
      select user_id, nickname, created_at,
             greatest(best_score, case when cur_ok then n_cur end) as n,
             case when hidden then 'hidden' when best_score > 0 or cur_ok then 'ok' else 'pending' end as status,
             %s as stage
      from vetted
    ), ranked as (
      select user_id, nickname, n as score, stage,
             rank() over (order by n desc) as rank,
             row_number() over (order by n desc, created_at, nickname) as rn
      from judged where status = 'ok'
    ), out as (
      select r.rn as k, r.rank, r.nickname, r.score, r.stage, coalesce(r.user_id = $2, false) as is_me, 'ok'::text as status
      from ranked r
      where r.rn <= $1 or r.user_id = $2
      union all
      select 9223372036854775807, null, j.nickname, null, null, true, j.status
      from judged j
      where j.status <> 'ok' and j.user_id = $2
    )
    select o.rank, o.nickname, o.score, o.stage::int, o.is_me, o.status from out o order by o.k $q$,
    -- Açık Ofis v2.2 applied: v6 rules (best_score/best_stage); not applied: exactly the v5 rules (current save only)
    case when ao_v22 then 's.best_score' else '0::numeric' end,
    case when ao_v22 then 's.best_stage' else '0' end,
    case when ao_v22
         then 'greatest(best_stage, case when cur_ok and jsonb_typeof(data -> ''stage'') = ''number'' then least(99, greatest(0, floor((data ->> ''stage'')::numeric)))::int else 0 end)'
         else 'case when jsonb_typeof(data -> ''stage'') = ''number'' then least(99, greatest(0, floor((data ->> ''stage'')::numeric)))::int end' end)
    using lim, uid;
end $fn$;
comment on function public.kodhane_leaderboard(int, text) is
  'Kodhane leaderboard (p_game kodhane; acik_ofis = compatibility path for the shared DB, empty if Açık Ofis is not installed): rank, nickname, score (numeric all-time best = GREATEST(best_score, plausible current totalEarned)), stage (all-time best = GREATEST(best_stage, plausible current stage)), is_me, status (ok|pending|hidden, own row only). No user ids. v6 (Kodhane v2.2 migration 20260928160000)';
revoke all on function public.kodhane_leaderboard(int, text) from public;
grant execute on function public.kodhane_leaderboard(int, text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------- function privileges
revoke all on function public.kodhane_config_int(text, int) from public, anon, authenticated;
revoke all on function public.kodhane_config_text(text, text) from public, anon, authenticated;
revoke all on function public.kodhane_save_backup_retention() from public, anon, authenticated;
revoke all on function public.kodhane_save_score(jsonb) from public, anon, authenticated;
revoke all on function public.kodhane_save_vetted_score(jsonb) from public, anon, authenticated;
revoke all on function public.kodhane_save_stage(jsonb) from public, anon, authenticated;
revoke all on function public.kodhane_save_stage_checked(jsonb) from public, anon, authenticated;
revoke all on function public.kodhane_save_vetted_stage(jsonb) from public, anon, authenticated;
revoke all on function public.kodhane_save_reset_payload(jsonb, numeric) from public, anon, authenticated;
revoke all on function public.kodhane_save_version_of(jsonb) from public, anon, authenticated;
revoke all on function public.kodhane_save_backups_trim(uuid) from public, anon, authenticated;
revoke all on function public.kodhane_cleanup_save_backups() from public, anon, authenticated;
revoke all on function public.kodhane_save_before_write() from public, anon, authenticated;
revoke all on function public.kodhane_save_before_delete() from public, anon, authenticated;
grant execute on function public.kodhane_cleanup_save_backups() to service_role;
-- the RLS policy on kodhane_save_backups evaluates the retention as the caller
grant execute on function public.kodhane_save_backup_retention() to authenticated;

revoke all on function public.kodhane_reset_save() from public, anon;
revoke all on function public.kodhane_restore_save(uuid) from public, anon;
revoke all on function public.kodhane_list_save_backups() from public, anon;
grant execute on function public.kodhane_reset_save() to authenticated, service_role;
grant execute on function public.kodhane_restore_save(uuid) to authenticated, service_role;
grant execute on function public.kodhane_list_save_backups() to authenticated, service_role;

-- ---------------------------------------------------------------- schedule: NOT here
-- Never creates the pg_cron extension, never schedules anything. Without a schedule, kodhane_reset_save/restore_save still
-- trim each player's own expired/over-cap backups; kodhane_cleanup_save_backups() (service_role) deletes all expired ones.
-- Optional daily job (03:17 TSİ), only where pg_cron is already enabled: supabase/ops/20260928160000_v2_2_kodhane_schedule_cleanup.sql

commit;
notify pgrst, 'reload schema';
