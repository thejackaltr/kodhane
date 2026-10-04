-- =====================================================================================================
-- Kodhane v4.4 backend: progress log (kazanç günlüğü), step 1 of plans/kodhane-telafi-otomasyon-kapsam.md.
-- Ships in the same release as package B (20260929204000); does not depend on A or B (needs Kodhane v2.2 only).
--
-- public.kodhane_progress_log: one row per changed field of a Kodhane cloud save write. Written ONLY by the server:
--   AFTER INSERT OR UPDATE trigger kodhane_saves_z_progress_log on public.kodhane_saves (SECURITY DEFINER, owner postgres,
--   search_path ''). A write that a BEFORE trigger refuses (v2.2 PT409 stale_revision / stale_write, B PT426
--   save_version_too_old) never reaches this trigger, so refused writes are never logged.
--   Fields (top-level keys of kodhane_saves.data, as in kodhane_score_plausible / game.js saveData):
--     shares, prestigeCount, cycleRounds             -> event 'yatirim_turu'
--     ipoCount                                       -> event 'halka_arz'
--     ipoShares (spendable), ipoSharesEarned (total) -> event 'borsa_payi'
--     tree (array of Borsa Payı Ağacı node ids)      -> event 'agac', one row per added (or removed) node id
--   A field counts as changed when coalesce(old, 0) <> coalesce(new, 0) (missing / non-number = no value); decreases
--   are logged too (e.g. ipoCount 2 -> 0). Values are stored as they are (NULL = missing / not a number).
--   Whole-write event types (override the field event):
--     'telafi'       the write runs with set_config('kodhane.progress_event', 'telafi', true) AND the caller's role is
--                    postgres / supabase_admin / service_role (role = current_setting('role'), else session_user; a
--                    SECURITY DEFINER RPC called by a player still counts as the player: role 'authenticated').
--                    It also needs set_config('kodhane.progress_ref', 'KD-TLF-YYYY-MM-DD-NN', true) (approval reference,
--                    stored in approval_ref; a valid date). Flag without a valid reference -> the save write is REFUSED
--                    (22023, admin work, not swallowed); a failing log insert of a telafi write is not swallowed either.
--     'sifirlama'    kodhane_reset_save() (its 'reset' backup of this revision was written in the same transaction)
--     'geri_yukleme' kodhane_restore_save() (its 'restore' backup, same rule)
-- Errors inside the trigger are caught (WARNING in the server log), the save write itself succeeds (player writes and admin
-- writes without the telafi flag; see 'telafi' above for the exception).
-- client_version: data.clientVersion if it is a string of 1..32 characters [0-9A-Za-z._-]; missing / JSON null ->
--   'saveVersion <n>'; any other value -> NULL.
-- No e-mail, no nickname. RLS on, no policy; anon / authenticated: no privilege at all (player read access comes with a
-- v4.5 RPC). service_role: SELECT only.
--
-- public.kodhane_cleanup_progress_log(p_retention_days integer, p_batch_size integer default 5000) returns integer:
--   deletes at most p_batch_size rows older than p_retention_days days (oldest first), returns the count. Default
--   retention 365 days (Aryen, 2026-10-03: 12 months, as the audit log). EXECUTE: postgres + service_role only.
--
-- Run (no -1; the file has its own transaction), as supabase_admin or postgres:
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261003020000_v4_4_kodhane_progress_log.sql
-- Idempotent. Rollback: supabase/rollback/20261003020000_v4_4_kodhane_progress_log.rollback.sql
-- Emergency switch without rollback: ALTER TABLE public.kodhane_saves DISABLE TRIGGER kodhane_saves_z_progress_log;
-- =====================================================================================================
begin;

do $pre$
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('public.kodhane_save_backups') is null
     or to_regclass('auth.users') is null then
    raise exception 'kodhane progress log: wrong target (public.kodhane_saves / kodhane_save_backups / auth.users missing in database %)', current_database();
  end if;
  if not exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.kodhane_saves'::regclass and attname = 'revision' and not attisdropped) then
    raise exception 'kodhane progress log: Kodhane v2.2 (20260928160000) is not applied here';
  end if;
end $pre$;

create table if not exists public.kodhane_progress_log (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  rev_before     bigint,                 -- kodhane_saves.revision before the write (NULL: first insert)
  rev_after      bigint,                 -- revision after the write (after the v2.2 trigger)
  client_version text,                   -- data.clientVersion (1..32 chars [0-9A-Za-z._-]); missing -> 'saveVersion <n>'; invalid -> NULL
  event          text not null constraint kodhane_progress_log_event_chk
                   check (event in ('yatirim_turu', 'halka_arz', 'borsa_payi', 'agac', 'telafi', 'sifirlama', 'geri_yukleme')),
  field          text not null constraint kodhane_progress_log_field_chk
                   check (field in ('shares', 'prestigeCount', 'cycleRounds', 'ipoCount', 'ipoShares', 'ipoSharesEarned', 'tree')),
  old_value      numeric,                -- tree: number of nodes before
  new_value      numeric,                -- tree: number of nodes after
  node_id        text,                   -- tree only: the added / removed node id (e.g. 'kod_1')
  actor_role     text not null,          -- role of the writer: authenticated (player), service_role, postgres, supabase_admin
  created_at     timestamptz not null default now(),
  approval_ref   text,                   -- telafi only: approval reference KD-TLF-YYYY-MM-DD-NN (kodhane.progress_ref); else NULL
  constraint kodhane_progress_log_node_chk check ((field = 'tree') = (node_id is not null) and (node_id is null or length(node_id) <= 40)),
  constraint kodhane_progress_log_ref_chk check ((event = 'telafi') = (approval_ref is not null)
    and (approval_ref is null or approval_ref ~ '^KD-TLF-[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])-[0-9]{2}$'))
);
comment on table public.kodhane_progress_log is
  'Kodhane progress log (v4.4): one row per changed save field (shares, prestigeCount, cycleRounds, ipoCount, ipoShares, ipoSharesEarned, tree node). Written only by trigger kodhane_saves_z_progress_log. No e-mail / nickname. Retention: kodhane_cleanup_progress_log(days). Players have no access.';
create index if not exists kodhane_progress_log_user_created_idx on public.kodhane_progress_log (user_id, created_at, id);
create index if not exists kodhane_progress_log_created_idx on public.kodhane_progress_log (created_at, id);
alter table public.kodhane_progress_log owner to postgres;
alter table public.kodhane_progress_log enable row level security;
revoke all on table public.kodhane_progress_log from public, anon, authenticated, service_role;
grant select on table public.kodhane_progress_log to service_role;
do $seq$
declare s text := pg_catalog.pg_get_serial_sequence('public.kodhane_progress_log', 'id');
begin
  execute format('revoke all on sequence %s from public, anon, authenticated, service_role', s);
end $seq$;

-- ---------------------------------------------------------------- trigger
create or replace function public.kodhane_progress_log_write()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  -- the caller's role: SET ROLE / PostgREST role if any (a SECURITY DEFINER function does not change it), else the login role
  v_role text := coalesce(nullif(pg_catalog.current_setting('role', true), 'none'), session_user::text);
  v_telafi boolean := v_role in ('postgres', 'supabase_admin', 'service_role')
                      and pg_catalog.current_setting('kodhane.progress_event', true) = 'telafi';
  v_ref text := pg_catalog.current_setting('kodhane.progress_ref', true);
  v_ref_ok boolean := false;
  o jsonb; n jsonb := new.data;
  v_rev_before bigint;
  v_event text; v_cv text; k text; ov numeric; nv numeric; ot text[]; nt text[];
  v_fields constant text[] := array['shares', 'prestigeCount', 'cycleRounds', 'ipoCount', 'ipoShares', 'ipoSharesEarned'];
begin
  -- telafi needs an approval reference. Checked OUTSIDE the error-swallowing block: a telafi write without a valid
  -- reference is refused as a whole (admin work; the admin sees the error and retries with the reference).
  if v_telafi then
    if v_ref ~ '^KD-TLF-[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])-[0-9]{2}$' then
      begin
        perform pg_catalog.substr(v_ref, 8, 10)::date;   -- real calendar date (no 2026-02-31)
        v_ref_ok := true;
      exception when others then v_ref_ok := false;
      end;
    end if;
    if not v_ref_ok then
      raise exception 'kodhane_progress_log: telafi write refused: kodhane.progress_ref must be an approval reference KD-TLF-YYYY-MM-DD-NN (got %)',
        coalesce(pg_catalog.quote_literal(left(v_ref, 40)), 'none')
        using errcode = '22023',
              hint = 'select set_config(''kodhane.progress_ref'', ''KD-TLF-2026-10-03-01'', true) in the same transaction';
    end if;
  end if;
  if tg_op = 'UPDATE' then
    if old.data is not distinct from new.data then return null; end if;
    o := old.data; v_rev_before := old.revision;
  end if;
  begin
    v_event := case
      when v_telafi then 'telafi'
      when tg_op = 'UPDATE' then
        (select case b.reason when 'reset' then 'sifirlama' else 'geri_yukleme' end
           from public.kodhane_save_backups b
          where b.user_id = new.user_id and b.revision = old.revision and b.reason in ('reset', 'restore')
            and b.created_at = pg_catalog.now()          -- written in this transaction (now() = transaction start)
          order by b.reason limit 1)
    end;
    v_cv := case
      when n -> 'clientVersion' is null or pg_catalog.jsonb_typeof(n -> 'clientVersion') = 'null' then
        'saveVersion ' || coalesce(
          case when pg_catalog.jsonb_typeof(n -> 'saveVersion') = 'number' then (n ->> 'saveVersion')::numeric end,
          case when pg_catalog.jsonb_typeof(n -> 'version') = 'number' then (n ->> 'version')::numeric end,
          new.save_version)::text
      when pg_catalog.jsonb_typeof(n -> 'clientVersion') = 'string' and (n ->> 'clientVersion') ~ '^[0-9A-Za-z._-]{1,32}$' then n ->> 'clientVersion'
    end;                                                  -- any other clientVersion (too long, other characters, not a string) -> NULL
    foreach k in array v_fields loop
      ov := case when pg_catalog.jsonb_typeof(o -> k) = 'number' then (o ->> k)::numeric end;
      nv := case when pg_catalog.jsonb_typeof(n -> k) = 'number' then (n ->> k)::numeric end;
      if coalesce(ov, 0) <> coalesce(nv, 0) then
        insert into public.kodhane_progress_log (user_id, rev_before, rev_after, client_version, event, field, old_value, new_value, actor_role, approval_ref)
        values (new.user_id, v_rev_before, new.revision, v_cv,
                coalesce(v_event, case k when 'ipoCount' then 'halka_arz' when 'ipoShares' then 'borsa_payi'
                                         when 'ipoSharesEarned' then 'borsa_payi' else 'yatirim_turu' end),
                k, ov, nv, v_role, case when v_telafi then v_ref end);
      end if;
    end loop;
    -- Borsa Payı Ağacı: data.tree = array of node id strings (game.js S.tree, buyNode pushes the id). Only strings that look
    -- like a node id ('<branch>_<n>'), first 64 distinct ones, in array order (a client cannot make one write log more).
    select coalesce(array_agg(x.v order by x.i), '{}') into ot from (
      select e #>> '{}' as v, min(i) as i
        from pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(o -> 'tree') = 'array' then o -> 'tree' else '[]' end) with ordinality j(e, i)
       where pg_catalog.jsonb_typeof(e) = 'string' and (e #>> '{}') ~ '^[a-z][a-z0-9]{0,19}_[0-9]{1,2}$'
       group by 1 order by 2 limit 64) x;
    select coalesce(array_agg(x.v order by x.i), '{}') into nt from (
      select e #>> '{}' as v, min(i) as i
        from pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(n -> 'tree') = 'array' then n -> 'tree' else '[]' end) with ordinality j(e, i)
       where pg_catalog.jsonb_typeof(e) = 'string' and (e #>> '{}') ~ '^[a-z][a-z0-9]{0,19}_[0-9]{1,2}$'
       group by 1 order by 2 limit 64) x;
    insert into public.kodhane_progress_log (user_id, rev_before, rev_after, client_version, event, field, old_value, new_value, node_id, actor_role, approval_ref)
    select new.user_id, v_rev_before, new.revision, v_cv, coalesce(v_event, 'agac'), 'tree', cardinality(ot), cardinality(nt), d.node, v_role,
           case when v_telafi then v_ref end
      from (select u.node, u.ord, 1 as grp from unnest(nt) with ordinality u(node, ord) where u.node <> all (ot)    -- added
            union all
            select u.node, u.ord, 2 from unnest(ot) with ordinality u(node, ord) where u.node <> all (nt)) d    -- removed
     order by d.grp, d.ord;
  exception when others then
    -- a telafi write is admin work and exists to be logged: its log failure refuses the write (re-raised)
    if v_telafi then raise; end if;
    -- never break the player's save write: the player's progress matters more than its log line (runbook: "hata yutma")
    raise warning 'kodhane_progress_log: not logged for this save write (SQLSTATE %: %); the save write itself is kept', sqlstate, sqlerrm;
  end;
  return null;
end $$;
alter function public.kodhane_progress_log_write() owner to postgres;
revoke all on function public.kodhane_progress_log_write() from public, anon, authenticated, service_role;
comment on function public.kodhane_progress_log_write() is
  'Kodhane v4.4 progress log: AFTER INSERT OR UPDATE trigger on kodhane_saves. Logs changed shares / prestigeCount / cycleRounds / ipoCount / ipoShares / ipoSharesEarned and added / removed tree nodes. Event telafi only with kodhane.progress_event = telafi AND caller role postgres / supabase_admin / service_role, and it needs kodhane.progress_ref = KD-TLF-YYYY-MM-DD-NN (else the write is refused). Errors -> WARNING, the save write is kept (not for telafi writes).';

drop trigger if exists kodhane_saves_z_progress_log on public.kodhane_saves;
create trigger kodhane_saves_z_progress_log after insert or update on public.kodhane_saves
  for each row execute function public.kodhane_progress_log_write();

-- ---------------------------------------------------------------- retention (365 days: Aryen, 2026-10-03)
create or replace function public.kodhane_cleanup_progress_log(p_retention_days integer default 365, p_batch_size integer default 5000)
returns integer language plpgsql volatile security definer set search_path = ''
as $$
declare n integer;
begin
  if p_retention_days is null or p_retention_days < 1 or p_retention_days > 3650 then
    raise exception 'kodhane_cleanup_progress_log: p_retention_days must be between 1 and 3650 (got %); nothing deleted', coalesce(p_retention_days::text, 'null')
      using errcode = '22023';
  end if;
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 50000 then
    raise exception 'kodhane_cleanup_progress_log: p_batch_size must be between 1 and 50000 (got %); nothing deleted', coalesce(p_batch_size::text, 'null')
      using errcode = '22023';
  end if;
  delete from public.kodhane_progress_log l
   where l.id in (select x.id from public.kodhane_progress_log x
                   where x.created_at < pg_catalog.now() - pg_catalog.make_interval(days => p_retention_days)
                   order by x.created_at, x.id
                   limit p_batch_size);
  get diagnostics n = row_count;
  return n;
end $$;
alter function public.kodhane_cleanup_progress_log(integer, integer) owner to postgres;
revoke all on function public.kodhane_cleanup_progress_log(integer, integer) from public, anon, authenticated;
grant execute on function public.kodhane_cleanup_progress_log(integer, integer) to service_role;
comment on function public.kodhane_cleanup_progress_log(integer, integer) is
  'Kodhane v4.4 progress log retention: deletes at most p_batch_size (1..50000) rows older than p_retention_days (1..3650) days, oldest first; returns the count. Default retention 365 days (Aryen, 2026-10-03).';

notify pgrst, 'reload schema';
commit;
