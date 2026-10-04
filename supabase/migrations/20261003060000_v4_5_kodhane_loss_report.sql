-- =====================================================================================================
-- Kodhane v4.5 backend, P7 "Kayıp bildir" (server side): loss report, Aryen's approval queue, restore from the progress log.
-- Scope: plans/kodhane-telafi-otomasyon-kapsam.md steps 2-3, plans/kodhane-v4.5-plan.md P7. Separate install step with its own
-- approval (docs/kodhane-loss-report-runbook.md). Needs package B (20260929204000) AND the progress log (20261003020000);
-- does NOT need the deletion log (20261003040000) and does not touch package B, the progress log or the deletion log objects.
--
-- kodhane_loss.loss_report: one row per player report. No e-mail, no nickname: the player is the auth uid
--   (FK auth.users ON DELETE CASCADE). Player fields (form): lost_items, lost_since, description, client_version; server
--   fields: created_at, save_revision (kodhane_saves.revision at report time). Ops fields (never shown to the player):
--   status history, approval_ref, approved_* (values, revision, reference time), ops_note, decided_by, applied_*, backup_id.
--   Own schema kodhane_loss (separate from the deletion log's kodhane_private, whose install check counts its functions):
--   no USAGE for anon / authenticated / service_role. Table owner postgres, RLS on + FORCE, no policy,
--   no privilege for anon / authenticated / service_role. Players reach it only through the two RPCs below.
--   Status: pending -> approved -> applied | pending/approved/needs_review -> rejected | approved -> needs_review (the save
--   revision changed between approval and apply) -> approved (approve again) ... At most ONE open report (pending, approved,
--   needs_review) per player (partial unique index).
-- Player RPCs (authenticated only; SECURITY DEFINER, owner postgres, search_path '', auth.uid()):
--   public.kodhane_loss_report_create(p_lost_items text[], p_lost_since timestamptz, p_description text, p_client_version text)
--     returns jsonb {id, status 'in_review', created_at}. Limits (kodhane_loss.cfg_loss_report()): 1 report per rolling
--     24 hours, 5 per 30 days, no new report while one is open, a Kodhane cloud save must exist. Errors (PostgREST status):
--     42501 not_authenticated, 22023 loss_report_invalid (detail = field), PT404 no_cloud_save, PT409 loss_report_open,
--     PT429 loss_report_daily_limit / loss_report_monthly_limit (detail = retry_after ISO time).
--   public.kodhane_loss_report_status(p_limit integer default 10): the caller's own reports, newest first:
--     id, created_at, lost_items, lost_since, status (in_review | approved | rejected | applied), status_changed_at,
--     reason (rejection code only), applied_at, review_reason (in_review only: save_changed | no_cloud_save | NULL = first
--     review), applied_revision (applied only: kodhane_saves.revision written by the restore, = applied_rev_after; NULL
--     otherwise; the client compares it with the revision its tab last saw: lower -> the tab is older than the restore).
--     No description, no ops field, no other player's row.
--   lost_since: timestamptz or NULL ("daha eski / bilmiyorum"); the client sends the start of the player's local day (Bugün /
--     Dün) or now - 7 / 30 days, as a UTC ISO time. Server: not more than 5 minutes in the future, at most 365 days back.
-- Ops functions (kodhane_loss, EXECUTE postgres only + an explicit caller check: postgres / supabase_admin):
--   loss_report_queue(p_status), loss_report_timeline(p_id, p_days), loss_report_proposal(p_id, p_at),
--   loss_report_approve(p_id, p_approval_ref, p_at, p_values, p_note, p_accept_implausible), loss_report_reject(p_id, p_reason, p_note),
--   loss_report_apply(p_id, p_approval_ref), cleanup_loss_reports().
--   Restore rule: the target of every logged field (shares, prestigeCount, cycleRounds, ipoCount, ipoShares, ipoSharesEarned)
--   is its value at the reference time p_at, rebuilt from public.kodhane_progress_log; Borsa Payı Ağacı: nodes the player
--   had at p_at. The write only RAISES: value = greatest(current, target), tree = current + missing nodes. Nothing else in
--   the save changes (totalEarned, saveVersion, stage ... stay), so best_score / leaderboard and B's version guard are not
--   affected. Apply = one transaction: lock -> revision still the approved one? (else status needs_review, no write) ->
--   'manual' backup of the current row -> write with kodhane.progress_event = telafi + kodhane.progress_ref = approval_ref
--   (the progress log writes event 'telafi' rows with that reference) -> status applied. Second call: 'already_applied',
--   no change. Never without approval: apply refuses unless status = approved AND the reference equals the approved one.
-- approval_ref: KD-TLF-YYYY-MM-DD-NN (real date; the progress log's format), one reference per report (unique); like the
--   account delete, refused with @ , " \ or a control character.
-- Retention (Aryen, 03.10.2026: 12 months): closed reports (applied / rejected) 12 months after the last status change
--   (cleanup_loss_reports(); scheduled by the daily retention command, separate approval); open reports stay until decided.
-- review_reason (re-review after an approval, set only by loss_report_apply): save_changed = the save revision changed after
--   the approval; no_cloud_save = no Kodhane cloud save any more or nothing left to restore. NULL = first review (CHECK). Account deletion
--   (ops/kodhane_account_delete.sql, both modes) deletes the player's reports.
--
-- Run (no -1; the file has its own transaction), as supabase_admin or postgres:
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/migrations/20261003060000_v4_5_kodhane_loss_report.sql
-- Check: supabase/ops/kodhane_loss_report/install_verify.sql. Idempotent.
-- Rollback: supabase/rollback/20261003060000_v4_5_kodhane_loss_report.rollback.sql (refuses while reports exist).
-- =====================================================================================================
begin;

do $pre$
begin
  if to_regclass('public.kodhane_saves') is null or to_regclass('public.kodhane_save_backups') is null
     or to_regclass('auth.users') is null then
    raise exception 'kodhane loss report: wrong target (public.kodhane_saves / kodhane_save_backups / auth.users missing in database %)', current_database();
  end if;
  if to_regclass('public.fenomen_saves') is not null then
    raise exception 'kodhane loss report: wrong target (public.fenomen_saves exists: this is a Fenomen database)';
  end if;
  if not exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgname = 'kodhane_saves_a_version_guard')
     or to_regprocedure('public.kodhane_leaderboard_v7(integer)') is null then
    raise exception 'kodhane loss report: package B (20260929204000) is not installed here; install B + progress log first';
  end if;
  if to_regclass('public.kodhane_progress_log') is null
     or not exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'public.kodhane_saves'::regclass and tgname = 'kodhane_saves_z_progress_log') then
    raise exception 'kodhane loss report: the progress log (20261003020000) is not installed here; install B + progress log first';
  end if;
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'postgres' and (rolbypassrls or rolsuper)) then
    raise exception 'kodhane loss report: role postgres missing or without BYPASSRLS (the table is FORCE ROW LEVEL SECURITY)';
  end if;
end $pre$;

create schema if not exists kodhane_loss authorization postgres;
alter schema kodhane_loss owner to postgres;
revoke all on schema kodhane_loss from public, anon, authenticated, service_role;
comment on schema kodhane_loss is 'Kodhane "Kayıp bildir" reports + approval queue, no API access (players only through public.kodhane_loss_report_create / _status). Migration 20261003060000.';

-- ---------------------------------------------------------------- config (single place for the numbers)
create or replace function kodhane_loss.cfg_loss_report()
returns jsonb language sql immutable set search_path = '' as $$
  select '{"per_24h": 1, "per_30_days": 5, "description_max": 280, "lost_since_max_days": 365, "lost_since_future_minutes": 5, "retention_months": 12,
           "lost_items": ["yatirim_turu", "halka_arz", "borsa_payi", "agac", "diger"],
           "reject_reasons": ["kayip_bulunamadi", "zaten_telafi_edildi", "kural_disi", "diger"],
           "review_reasons": ["save_changed", "no_cloud_save"],
           "fields": ["shares", "prestigeCount", "cycleRounds", "ipoCount", "ipoShares", "ipoSharesEarned"]}'::jsonb $$;
comment on function kodhane_loss.cfg_loss_report() is
  'Kodhane loss report limits: 1 per 24 h, 5 per 30 days, description <= 280, lost_since <= 365 days back and <= 5 min ahead, closed reports kept 12 months.';

-- ---------------------------------------------------------------- table
create table if not exists kodhane_loss.loss_report (
  id                 bigint generated always as identity primary key,
  user_id            uuid not null references auth.users(id) on delete cascade,
  created_at         timestamptz not null default now(),
  -- player (form) fields
  lost_items         text[] not null constraint loss_report_lost_items_check
                       check (cardinality(lost_items) between 1 and 5
                              and lost_items <@ array['yatirim_turu', 'halka_arz', 'borsa_payi', 'agac', 'diger']::text[]),
  lost_since         timestamptz,
  description        text constraint loss_report_description_check
                       check (description is null or (length(description) between 1 and 280 and position('@' in description) = 0)),
  client_version     text constraint loss_report_client_version_check check (client_version is null or client_version ~ '^[0-9A-Za-z._-]{1,32}$'),
  save_revision      bigint,
  -- queue / ops fields (never shown to the player)
  status             text not null default 'pending' constraint loss_report_status_check
                       check (status in ('pending', 'approved', 'rejected', 'applied', 'needs_review')),
  status_changed_at  timestamptz not null default now(),
  approval_ref       text constraint loss_report_approval_ref_check
                       check (approval_ref is null or approval_ref ~ '^KD-TLF-[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])-[0-9]{2}$'),
  ref_at             timestamptz,
  approved_values    jsonb,
  approved_revision  bigint,
  approved_at        timestamptz,
  plausible_before   boolean,
  plausible_after    boolean,
  reject_reason      text constraint loss_report_reject_reason_check
                       check (reject_reason is null or reject_reason in ('kayip_bulunamadi', 'zaten_telafi_edildi', 'kural_disi', 'diger')),
  ops_note           text constraint loss_report_ops_note_check check (ops_note is null or length(ops_note) <= 1000),
  decided_by         text,
  review_count       integer not null default 0,
  review_reason      text constraint loss_report_review_reason_check
                       check (review_reason is null or review_reason in ('save_changed', 'no_cloud_save')),
  applied_at         timestamptz,
  applied_rev_before bigint,
  applied_rev_after  bigint,
  applied_diff       jsonb,
  backup_id          uuid,
  constraint loss_report_approval_ref_key unique (approval_ref),
  constraint loss_report_state_check check (
    case status
      when 'pending'      then approved_at is null and applied_at is null and reject_reason is null and review_reason is null
      when 'approved'     then approval_ref is not null and approved_values is not null and approved_revision is not null
                               and approved_at is not null and applied_at is null and reject_reason is null
      when 'needs_review' then approval_ref is not null and applied_at is null and reject_reason is null and review_reason is not null
      when 'applied'      then approval_ref is not null and approved_values is not null and applied_at is not null
                               and applied_rev_after is not null and reject_reason is null
      when 'rejected'     then reject_reason is not null and applied_at is null
    end)
);
comment on table kodhane_loss.loss_report is
  'Kodhane "Kayıp bildir" reports + Aryen''s approval queue (migration 20261003060000). uid only, no e-mail / nickname. Players: public.kodhane_loss_report_create / _status. Ops: kodhane_loss.loss_report_* (postgres).';
create unique index if not exists loss_report_one_open_idx on kodhane_loss.loss_report (user_id)
  where status in ('pending', 'approved', 'needs_review');
create index if not exists loss_report_user_created_idx on kodhane_loss.loss_report (user_id, created_at);
create index if not exists loss_report_status_idx on kodhane_loss.loss_report (status, created_at);
alter table kodhane_loss.loss_report owner to postgres;
alter table kodhane_loss.loss_report enable row level security;
alter table kodhane_loss.loss_report force row level security;
revoke all on table kodhane_loss.loss_report from public, anon, authenticated, service_role;
do $seq$
declare s text := pg_catalog.pg_get_serial_sequence('kodhane_loss.loss_report', 'id');
begin
  execute format('alter sequence %s owner to postgres', s);
  execute format('revoke all on sequence %s from public, anon, authenticated, service_role', s);
end $seq$;

-- ---------------------------------------------------------------- helpers (ops)
-- caller check of every ops function: postgres / supabase_admin only (SET ROLE / PostgREST role first, else the login role)
create or replace function kodhane_loss.loss_report_assert_ops()
returns void language plpgsql stable set search_path = '' as $$
declare v_role text := coalesce(nullif(pg_catalog.current_setting('role', true), 'none'), session_user::text);
begin
  if v_role not in ('postgres', 'supabase_admin') then
    raise exception 'kodhane loss report: ops functions are for postgres / supabase_admin only (caller %)', v_role using errcode = '42501';
  end if;
end $$;

-- approval reference: same character rule as ops/kodhane_account_delete.sql, then the progress log's KD-TLF format
create or replace function kodhane_loss.loss_report_check_ref(p_ref text)
returns text language plpgsql immutable set search_path = '' as $$
declare v text := btrim(coalesce(p_ref, ''));
begin
  if length(v) < 4 then
    raise exception 'kodhane loss report: approval_ref (Aryen''s approval reference) is required; nothing changed' using errcode = '22023';
  end if;
  if length(v) > 200 or v ~ '[@,"\\[:cntrl:]]' then
    raise exception 'kodhane loss report: approval_ref must be at most 200 characters without @ , " \ or control characters (no e-mail address); nothing changed'
      using errcode = '22023';
  end if;
  if v !~ '^KD-TLF-[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])-[0-9]{2}$' then
    raise exception 'kodhane loss report: approval_ref must be KD-TLF-YYYY-MM-DD-NN (got %); nothing changed', pg_catalog.quote_literal(left(v, 40))
      using errcode = '22023';
  end if;
  begin
    perform pg_catalog.substr(v, 8, 10)::date;
  exception when others then
    raise exception 'kodhane loss report: approval_ref % has no real date; nothing changed', pg_catalog.quote_literal(v) using errcode = '22023';
  end;
  return v;
end $$;

-- logged fields of a save (numbers only; anything else = NULL) + its tree node ids (same filter as the progress log)
create or replace function kodhane_loss.loss_report_fields(d jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select pg_catalog.jsonb_build_object(
    'shares',          case when pg_catalog.jsonb_typeof(d -> 'shares') = 'number' then d -> 'shares' end,
    'prestigeCount',   case when pg_catalog.jsonb_typeof(d -> 'prestigeCount') = 'number' then d -> 'prestigeCount' end,
    'cycleRounds',     case when pg_catalog.jsonb_typeof(d -> 'cycleRounds') = 'number' then d -> 'cycleRounds' end,
    'ipoCount',        case when pg_catalog.jsonb_typeof(d -> 'ipoCount') = 'number' then d -> 'ipoCount' end,
    'ipoShares',       case when pg_catalog.jsonb_typeof(d -> 'ipoShares') = 'number' then d -> 'ipoShares' end,
    'ipoSharesEarned', case when pg_catalog.jsonb_typeof(d -> 'ipoSharesEarned') = 'number' then d -> 'ipoSharesEarned' end,
    'tree', coalesce((select pg_catalog.jsonb_agg(x.v order by x.i) from (
        select e #>> '{}' as v, min(i) as i
          from pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(d -> 'tree') = 'array' then d -> 'tree' else '[]' end) with ordinality j(e, i)
         where pg_catalog.jsonb_typeof(e) = 'string' and (e #>> '{}') ~ '^[a-z][a-z0-9]{0,19}_[0-9]{1,2}$'
         group by 1 order by 2 limit 64) x), '[]'::jsonb))
$$;

-- state of the logged fields at p_at, rebuilt from the progress log over the current save d:
--   number field: new_value of the last log row at or before p_at; none -> old_value of the first row after p_at; none -> current
--   tree: current nodes, the tree rows after p_at undone newest first (node present -> it was added then -> remove; else add back)
create or replace function kodhane_loss.loss_report_state_at(p_uid uuid, p_at timestamptz, d jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  cur jsonb := kodhane_loss.loss_report_fields(d);
  res jsonb := '{}'; k text; r record; v jsonb; t text[]; back text[] := '{}';
begin
  foreach k in array array['shares', 'prestigeCount', 'cycleRounds', 'ipoCount', 'ipoShares', 'ipoSharesEarned'] loop
    select l.new_value into r from public.kodhane_progress_log l
     where l.user_id = p_uid and l.field = k and l.created_at <= p_at order by l.id desc limit 1;
    if found then v := pg_catalog.to_jsonb(r.new_value);
    else
      select l.old_value into r from public.kodhane_progress_log l
       where l.user_id = p_uid and l.field = k and l.created_at > p_at order by l.id limit 1;
      v := case when found then pg_catalog.to_jsonb(r.old_value) else cur -> k end;
    end if;
    res := res || pg_catalog.jsonb_build_object(k, coalesce(v, 'null'::jsonb));
  end loop;
  select coalesce(array_agg(e order by i), '{}') into t from pg_catalog.jsonb_array_elements_text(cur -> 'tree') with ordinality x(e, i);
  -- newest first: a node present in the rebuilt state was added by that write -> remove it; absent -> it was removed -> add
  -- it back (kept in 'back', ascending log order = the order the player had them)
  for r in select l.node_id from public.kodhane_progress_log l
            where l.user_id = p_uid and l.field = 'tree' and l.created_at > p_at order by l.id desc loop
    if r.node_id = any (t) then t := pg_catalog.array_remove(t, r.node_id);
    elsif r.node_id = any (back) then back := pg_catalog.array_remove(back, r.node_id);
    else back := r.node_id || back;
    end if;
  end loop;
  return res || pg_catalog.jsonb_build_object('tree', pg_catalog.to_jsonb(t || back));
end $$;

-- validated absolute targets (Aryen's corrected amounts): keys = logged fields and/or tree; numbers 0..1e50; tree = node ids
create or replace function kodhane_loss.loss_report_check_values(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare k text; v jsonb; n numeric;
begin
  if p is null or pg_catalog.jsonb_typeof(p) <> 'object' or p = '{}'::jsonb then
    raise exception 'kodhane loss report: p_values must be a non-empty JSON object' using errcode = '22023';
  end if;
  for k, v in select * from pg_catalog.jsonb_each(p) loop
    if k = 'tree' then
      if pg_catalog.jsonb_typeof(v) <> 'array' or pg_catalog.jsonb_array_length(v) > 64
         or exists (select 1 from pg_catalog.jsonb_array_elements(v) e
                     where pg_catalog.jsonb_typeof(e) <> 'string' or (e #>> '{}') !~ '^[a-z][a-z0-9]{0,19}_[0-9]{1,2}$') then
        raise exception 'kodhane loss report: p_values.tree must be an array of at most 64 node ids like "kod_1"' using errcode = '22023';
      end if;
    elsif k in ('shares', 'prestigeCount', 'cycleRounds', 'ipoCount', 'ipoShares', 'ipoSharesEarned') then
      if pg_catalog.jsonb_typeof(v) <> 'number' then
        raise exception 'kodhane loss report: p_values.% must be a number', k using errcode = '22023';
      end if;
      n := (v #>> '{}')::numeric;
      if n < 0 or n > 1e50 then
        raise exception 'kodhane loss report: p_values.% must be between 0 and 1e50 (got %)', k, n using errcode = '22023';
      end if;
    else
      raise exception 'kodhane loss report: p_values key % is not a restorable field (shares, prestigeCount, cycleRounds, ipoCount, ipoShares, ipoSharesEarned, tree)', k
        using errcode = '22023';
    end if;
  end loop;
  return p;
end $$;

-- what a write of the targets p_target onto save d does: {"data": merged save, "diff": {field: {from, to}}, "tree_add": [...]}
-- only raises: greatest(current, target); tree: current + missing target nodes (appended); missing / non-number current = 0
create or replace function kodhane_loss.loss_report_merge(d jsonb, p_target jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  cur jsonb := kodhane_loss.loss_report_fields(d);
  k text; c numeric; t numeric; diff jsonb := '{}'; add jsonb := '[]'; out jsonb := d;
begin
  foreach k in array array['shares', 'prestigeCount', 'cycleRounds', 'ipoCount', 'ipoShares', 'ipoSharesEarned'] loop
    if pg_catalog.jsonb_typeof(p_target -> k) = 'number' then
      c := coalesce((cur ->> k)::numeric, 0); t := (p_target ->> k)::numeric;
      if t > c then
        out := out || pg_catalog.jsonb_build_object(k, t);
        diff := diff || pg_catalog.jsonb_build_object(k, pg_catalog.jsonb_build_object('from', cur -> k, 'to', t));
      end if;
    end if;
  end loop;
  if pg_catalog.jsonb_typeof(p_target -> 'tree') = 'array' then
    select coalesce(pg_catalog.jsonb_agg(e order by i), '[]') into add
      from (select e, min(i) as i from pg_catalog.jsonb_array_elements(p_target -> 'tree') with ordinality x(e, i)
             where not (cur -> 'tree') @> pg_catalog.jsonb_build_array(e) group by e) y;
    if add <> '[]'::jsonb then
      out := pg_catalog.jsonb_set(out, '{tree}', (case when pg_catalog.jsonb_typeof(d -> 'tree') = 'array' then d -> 'tree' else '[]' end) || add);
      diff := diff || pg_catalog.jsonb_build_object('tree', pg_catalog.jsonb_build_object('from', pg_catalog.jsonb_array_length(cur -> 'tree'),
                                                                                          'to', pg_catalog.jsonb_array_length(cur -> 'tree') + pg_catalog.jsonb_array_length(add)));
    end if;
  end if;
  return pg_catalog.jsonb_build_object('data', out, 'diff', diff, 'tree_add', add);
end $$;

-- return columns changed (review_reason, then applied_revision as the last column) after the first local draft: drop an
-- older definition first (CREATE OR REPLACE cannot change OUT columns); owner, REVOKE and GRANT EXECUTE run again below
do $st$
begin
  if to_regprocedure('public.kodhane_loss_report_status(integer)') is not null
     and pg_catalog.pg_get_function_result(to_regprocedure('public.kodhane_loss_report_status(integer)')) not like '%review_reason text, applied_revision bigint)' then
    drop function public.kodhane_loss_report_status(integer);
  end if;
  if to_regprocedure('kodhane_loss.loss_report_queue(text)') is not null
     and pg_catalog.pg_get_function_result(to_regprocedure('kodhane_loss.loss_report_queue(text)')) not like '%review_reason text%' then
    drop function kodhane_loss.loss_report_queue(text);
  end if;
end $st$;
-- ---------------------------------------------------------------- ops functions (Aryen's queue)
create or replace function kodhane_loss.loss_report_queue(p_status text default 'open')
returns table (id bigint, user_id uuid, created_at timestamptz, status text, lost_items text[], lost_since timestamptz,
               description text, client_version text, save_revision bigint, current_revision bigint, approval_ref text,
               approved_revision bigint, review_count integer, review_reason text, reject_reason text, applied_at timestamptz)
language plpgsql stable set search_path = '' as $$
begin
  perform kodhane_loss.loss_report_assert_ops();
  if p_status not in ('open', 'all', 'pending', 'approved', 'rejected', 'applied', 'needs_review') then
    raise exception 'kodhane loss report queue: p_status must be open | all | pending | approved | rejected | applied | needs_review' using errcode = '22023';
  end if;
  return query
    select r.id, r.user_id, r.created_at, r.status, r.lost_items, r.lost_since, r.description, r.client_version, r.save_revision,
           s.revision, r.approval_ref, r.approved_revision, r.review_count, r.review_reason, r.reject_reason, r.applied_at
      from kodhane_loss.loss_report r
      left join public.kodhane_saves s on s.user_id = r.user_id
     where p_status = 'all' or r.status = p_status or (p_status = 'open' and r.status in ('pending', 'approved', 'needs_review'))
     order by r.created_at, r.id;
end $$;

-- progress log rows of the report's player from p_days before lost_since (or the report) until now
create or replace function kodhane_loss.loss_report_timeline(p_id bigint, p_days integer default 7)
returns table (log_id bigint, created_at timestamptz, event text, field text, old_value numeric, new_value numeric, node_id text,
               rev_before bigint, rev_after bigint, client_version text, actor_role text, approval_ref text)
language plpgsql stable set search_path = '' as $$
declare r record;
begin
  perform kodhane_loss.loss_report_assert_ops();
  select x.user_id, coalesce(x.lost_since, x.created_at) as t into r from kodhane_loss.loss_report x where x.id = p_id;
  if not found then raise exception 'kodhane loss report %: not found', p_id using errcode = '22023'; end if;
  if p_days is null or p_days < 1 or p_days > 365 then raise exception 'kodhane loss report: p_days must be 1..365' using errcode = '22023'; end if;
  return query
    select l.id, l.created_at, l.event, l.field, l.old_value, l.new_value, l.node_id, l.rev_before, l.rev_after, l.client_version, l.actor_role, l.approval_ref
      from public.kodhane_progress_log l
     where l.user_id = r.user_id and l.created_at >= r.t - pg_catalog.make_interval(days => p_days)
     order by l.id;
end $$;

-- proposal: state at p_at (default lost_since) vs the current save; read only
create or replace function kodhane_loss.loss_report_proposal(p_id bigint, p_at timestamptz default null)
returns jsonb language plpgsql stable set search_path = '' as $$
declare r record; s record; v_at timestamptz; at_state jsonb; m jsonb; cfg jsonb := kodhane_loss.cfg_loss_report();
begin
  perform kodhane_loss.loss_report_assert_ops();
  select x.* into r from kodhane_loss.loss_report x where x.id = p_id;
  if not found then raise exception 'kodhane loss report %: not found', p_id using errcode = '22023'; end if;
  v_at := coalesce(p_at, r.lost_since);
  if v_at is null then
    raise exception 'kodhane loss report %: no lost_since in the report; pass p_at (the time BEFORE the loss, see loss_report_timeline)', p_id using errcode = '22023';
  end if;
  if v_at > now() or v_at < now() - pg_catalog.make_interval(days => (cfg ->> 'lost_since_max_days')::int) then
    raise exception 'kodhane loss report %: p_at must be within the last % days', p_id, cfg ->> 'lost_since_max_days' using errcode = '22023';
  end if;
  select x.data, x.revision into s from public.kodhane_saves x where x.user_id = r.user_id;
  if not found then raise exception 'kodhane loss report %: the player has no Kodhane cloud save', p_id using errcode = '22023'; end if;
  at_state := kodhane_loss.loss_report_state_at(r.user_id, v_at, s.data);
  m := kodhane_loss.loss_report_merge(s.data, at_state);
  return pg_catalog.jsonb_build_object(
    'report_id', r.id, 'user_id', r.user_id, 'status', r.status, 'at', v_at, 'revision', s.revision,
    'current', kodhane_loss.loss_report_fields(s.data), 'at_state', at_state,
    'diff', m -> 'diff', 'tree_add', m -> 'tree_add', 'nothing_to_restore', (m -> 'diff') = '{}'::jsonb,
    'plausible_now', public.kodhane_score_plausible(s.data), 'plausible_after', public.kodhane_score_plausible(m -> 'data'));
end $$;

-- approve: pending / needs_review -> approved. Targets = state at p_at (default lost_since) or Aryen's p_values. Records the
-- save revision the targets were checked against; apply writes only while the save is still at that revision.
create or replace function kodhane_loss.loss_report_approve(p_id bigint, p_approval_ref text, p_at timestamptz default null,
                                                               p_values jsonb default null, p_note text default null,
                                                               p_accept_implausible boolean default false)
returns jsonb language plpgsql volatile set search_path = '' as $$
declare r record; s record; v_ref text; v_target jsonb; m jsonb; pb boolean; pa boolean; v_at timestamptz;
begin
  perform kodhane_loss.loss_report_assert_ops();
  v_ref := kodhane_loss.loss_report_check_ref(p_approval_ref);
  if p_note is not null and length(p_note) > 1000 then raise exception 'kodhane loss report: p_note at most 1000 characters' using errcode = '22023'; end if;
  select x.* into r from kodhane_loss.loss_report x where x.id = p_id for update;
  if not found then raise exception 'kodhane loss report %: not found', p_id using errcode = '22023'; end if;
  if r.status = 'approved' and r.approval_ref = v_ref then
    return pg_catalog.jsonb_build_object('result', 'already_approved', 'report_id', r.id, 'approval_ref', r.approval_ref,
                                         'approved_revision', r.approved_revision, 'approved_values', r.approved_values);
  end if;
  if r.status not in ('pending', 'needs_review') then
    raise exception 'kodhane loss report %: status % cannot be approved (only pending / needs_review)', p_id, r.status using errcode = '55000';
  end if;
  if r.approval_ref is not null and r.approval_ref <> v_ref then
    raise exception 'kodhane loss report %: already has approval_ref %; approve again with the same reference', p_id, r.approval_ref using errcode = '22023';
  end if;
  if exists (select 1 from kodhane_loss.loss_report x where x.approval_ref = v_ref and x.id <> p_id) then
    raise exception 'kodhane loss report %: approval_ref % is used by another report (one reference per report)', p_id, v_ref using errcode = '23505';
  end if;
  select x.data, x.revision into s from public.kodhane_saves x where x.user_id = r.user_id for update;
  if not found then raise exception 'kodhane loss report %: the player has no Kodhane cloud save', p_id using errcode = '22023'; end if;
  if p_values is not null then
    v_target := kodhane_loss.loss_report_check_values(p_values);
    v_at := p_at;
  else
    v_at := (kodhane_loss.loss_report_proposal(p_id, p_at) ->> 'at')::timestamptz;
    v_target := kodhane_loss.loss_report_state_at(r.user_id, v_at, s.data);
  end if;
  m := kodhane_loss.loss_report_merge(s.data, v_target);
  if (m -> 'diff') = '{}'::jsonb then
    raise exception 'kodhane loss report %: nothing to restore (every target <= the current save); reject the report instead', p_id using errcode = '22023';
  end if;
  pb := public.kodhane_score_plausible(s.data); pa := public.kodhane_score_plausible(m -> 'data');
  if pb and not pa and not coalesce(p_accept_implausible, false) then
    raise exception 'kodhane loss report %: the restored save would fail the score rule (kodhane_score_plausible; the player would leave the leaderboard). Lower the amounts (p_values) or pass p_accept_implausible => true', p_id
      using errcode = '22023';
  end if;
  update kodhane_loss.loss_report x
     set status = 'approved', status_changed_at = now(), approval_ref = v_ref, ref_at = v_at,
         approved_values = (select pg_catalog.jsonb_object_agg(k, case when k = 'tree' then m -> 'tree_add' else v_target -> k end)
                              from pg_catalog.jsonb_object_keys(m -> 'diff') k),
         approved_revision = s.revision, approved_at = now(), plausible_before = pb, plausible_after = pa,
         ops_note = coalesce(p_note, x.ops_note), decided_by = coalesce(nullif(pg_catalog.current_setting('role', true), 'none'), session_user::text)
   where x.id = p_id;
  return pg_catalog.jsonb_build_object('result', 'approved', 'report_id', p_id, 'approval_ref', v_ref, 'approved_revision', s.revision,
                                       'diff', m -> 'diff', 'plausible_before', pb, 'plausible_after', pa);
end $$;

create or replace function kodhane_loss.loss_report_reject(p_id bigint, p_reason text, p_note text default null)
returns jsonb language plpgsql volatile set search_path = '' as $$
declare r record;
begin
  perform kodhane_loss.loss_report_assert_ops();
  if p_reason is null or not (kodhane_loss.cfg_loss_report() -> 'reject_reasons') ? p_reason then
    raise exception 'kodhane loss report: p_reason must be one of %', kodhane_loss.cfg_loss_report() -> 'reject_reasons' using errcode = '22023';
  end if;
  if p_note is not null and length(p_note) > 1000 then raise exception 'kodhane loss report: p_note at most 1000 characters' using errcode = '22023'; end if;
  select x.* into r from kodhane_loss.loss_report x where x.id = p_id for update;
  if not found then raise exception 'kodhane loss report %: not found', p_id using errcode = '22023'; end if;
  if r.status = 'rejected' then
    return pg_catalog.jsonb_build_object('result', 'already_rejected', 'report_id', p_id, 'reason', r.reject_reason);
  end if;
  if r.status = 'applied' then
    raise exception 'kodhane loss report %: already applied; cannot be rejected', p_id using errcode = '55000';
  end if;
  update kodhane_loss.loss_report x
     set status = 'rejected', status_changed_at = now(), reject_reason = p_reason, ops_note = coalesce(p_note, x.ops_note),
         decided_by = coalesce(nullif(pg_catalog.current_setting('role', true), 'none'), session_user::text)
   where x.id = p_id;
  return pg_catalog.jsonb_build_object('result', 'rejected', 'report_id', p_id, 'reason', p_reason);
end $$;

-- apply: the only function that writes a save. Approved report + the same approval_ref, else refused.
create or replace function kodhane_loss.loss_report_apply(p_id bigint, p_approval_ref text)
returns jsonb language plpgsql volatile set search_path = '' as $$
declare r record; s record; v_ref text; m jsonb; v_bid uuid; v_rev bigint; n bigint;
begin
  perform kodhane_loss.loss_report_assert_ops();
  v_ref := kodhane_loss.loss_report_check_ref(p_approval_ref);
  select x.* into r from kodhane_loss.loss_report x where x.id = p_id for update;
  if not found then raise exception 'kodhane loss report %: not found', p_id using errcode = '22023'; end if;
  if r.status = 'applied' and r.approval_ref = v_ref then   -- idempotent: the second call changes nothing
    return pg_catalog.jsonb_build_object('result', 'already_applied', 'report_id', p_id, 'approval_ref', v_ref,
                                         'revision_after', r.applied_rev_after, 'diff', r.applied_diff, 'applied_at', r.applied_at);
  end if;
  if r.status not in ('approved', 'applied') then
    raise exception 'kodhane loss report %: status % is not approved; nothing written (approve with loss_report_approve first)', p_id, r.status
      using errcode = '55000';
  end if;
  if r.approval_ref is distinct from v_ref then
    raise exception 'kodhane loss report %: approval_ref does not match the approved reference; nothing written', p_id using errcode = '42501';
  end if;
  select x.data, x.revision, x.best_score, x.best_stage into s from public.kodhane_saves x where x.user_id = r.user_id for update;
  if not found then
    update kodhane_loss.loss_report x set status = 'needs_review', status_changed_at = now(), review_count = x.review_count + 1,
           review_reason = 'no_cloud_save' where x.id = p_id;
    return pg_catalog.jsonb_build_object('result', 'needs_review', 'report_id', p_id, 'review_reason', 'no_cloud_save',
                                         'note', 'the player has no Kodhane cloud save any more; nothing written');
  end if;
  if s.revision <> r.approved_revision then   -- scope 6a: the save changed since the approval -> "yeniden incele", no write
    update kodhane_loss.loss_report x set status = 'needs_review', status_changed_at = now(), review_count = x.review_count + 1,
           review_reason = 'save_changed' where x.id = p_id;
    return pg_catalog.jsonb_build_object('result', 'needs_review', 'report_id', p_id, 'review_reason', 'save_changed', 'approved_revision', r.approved_revision,
                                         'current_revision', s.revision, 'note', 'the save changed since the approval; nothing written. Check the proposal and approve again');
  end if;
  m := kodhane_loss.loss_report_merge(s.data, r.approved_values);
  if (m -> 'diff') = '{}'::jsonb then
    update kodhane_loss.loss_report x set status = 'needs_review', status_changed_at = now(), review_count = x.review_count + 1,
           review_reason = 'no_cloud_save' where x.id = p_id;
    return pg_catalog.jsonb_build_object('result', 'needs_review', 'report_id', p_id, 'review_reason', 'no_cloud_save',
                                         'note', 'nothing to restore any more; nothing written');
  end if;
  insert into public.kodhane_save_backups (user_id, revision, payload, best_score, best_stage, reason)
  values (r.user_id, s.revision, s.data, s.best_score, s.best_stage, 'manual') returning id into v_bid;
  perform pg_catalog.set_config('kodhane.progress_event', 'telafi', true), pg_catalog.set_config('kodhane.progress_ref', v_ref, true);
  update public.kodhane_saves x set data = m -> 'data', revision = s.revision + 1, updated_at = now()
   where x.user_id = r.user_id returning x.revision into v_rev;
  perform pg_catalog.set_config('kodhane.progress_event', '', true), pg_catalog.set_config('kodhane.progress_ref', '', true);
  select count(*) into n from public.kodhane_progress_log l
   where l.user_id = r.user_id and l.rev_after = v_rev and l.event = 'telafi' and l.approval_ref = v_ref;
  if n = 0 then
    raise exception 'kodhane loss report %: the progress log wrote no telafi row; rolled back', p_id;
  end if;
  update kodhane_loss.loss_report x
     set status = 'applied', status_changed_at = now(), applied_at = now(), applied_rev_before = s.revision, applied_rev_after = v_rev,
         applied_diff = m -> 'diff', backup_id = v_bid
   where x.id = p_id;
  return pg_catalog.jsonb_build_object('result', 'applied', 'report_id', p_id, 'approval_ref', v_ref, 'revision_before', s.revision,
                                       'revision_after', v_rev, 'diff', m -> 'diff', 'log_rows', n, 'backup_id', v_bid);
end $$;

-- retention: closed reports (applied / rejected) older than retention_months (12, Aryen) after their last status change
create or replace function kodhane_loss.cleanup_loss_reports()
returns integer language plpgsql volatile set search_path = '' as $$
declare n integer;
begin
  perform kodhane_loss.loss_report_assert_ops();
  delete from kodhane_loss.loss_report r
   where r.status in ('applied', 'rejected')
     and r.status_changed_at < now() - pg_catalog.make_interval(months => (kodhane_loss.cfg_loss_report() ->> 'retention_months')::int);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- player RPCs
create or replace function public.kodhane_loss_report_create(p_lost_items text[], p_lost_since timestamptz default null,
                                                             p_description text default null, p_client_version text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  cfg jsonb := kodhane_loss.cfg_loss_report();
  v_items text[]; v_desc text; v_cv text; v_rev bigint; v_last timestamptz; v_n30 bigint; v_first30 timestamptz; v_id bigint; v_at timestamptz;
begin
  if uid is null then raise exception using errcode = '42501', message = 'not_authenticated'; end if;
  -- input
  select array_agg(distinct x order by x) into v_items from unnest(p_lost_items) x;
  if v_items is null or cardinality(v_items) < 1 or cardinality(v_items) > 5 or array_position(v_items, null) is not null
     or not v_items <@ array(select pg_catalog.jsonb_array_elements_text(cfg -> 'lost_items')) then
    raise exception using errcode = '22023', message = 'loss_report_invalid', detail = 'lost_items',
      hint = 'one or more of yatirim_turu, halka_arz, borsa_payi, agac, diger';
  end if;
  if p_lost_since is not null and (p_lost_since > now() + pg_catalog.make_interval(mins => (cfg ->> 'lost_since_future_minutes')::int)
     or p_lost_since < now() - pg_catalog.make_interval(days => (cfg ->> 'lost_since_max_days')::int)) then
    raise exception using errcode = '22023', message = 'loss_report_invalid', detail = 'lost_since',
      hint = format('at most %s minutes in the future, at most %s days back; NULL = unknown', cfg ->> 'lost_since_future_minutes', cfg ->> 'lost_since_max_days');
  end if;
  v_desc := nullif(btrim(replace(coalesce(p_description, ''), E'\r\n', E'\n'), E' \t\n'), '');
  if v_desc is not null and (length(v_desc) > (cfg ->> 'description_max')::int or v_desc ~ '[\x01-\x08\x0b-\x1f\x7f]'
                             or position('@' in v_desc) > 0) then
    raise exception using errcode = '22023', message = 'loss_report_invalid', detail = 'description',
      hint = format('at most %s characters, no e-mail address (@), no control characters', cfg ->> 'description_max');
  end if;
  v_cv := case when p_client_version ~ '^[0-9A-Za-z._-]{1,32}$' then p_client_version end;   -- anything else: not stored
  -- one player at a time (two tabs / double click)
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('kodhane_loss_report:' || uid::text, 0));
  select s.revision into v_rev from public.kodhane_saves s where s.user_id = uid;
  if not found then raise exception using errcode = 'PT404', message = 'no_cloud_save', hint = 'save the game to the cloud first'; end if;
  if exists (select 1 from kodhane_loss.loss_report r where r.user_id = uid and r.status in ('pending', 'approved', 'needs_review')) then
    raise exception using errcode = 'PT409', message = 'loss_report_open', hint = 'one open report at a time';
  end if;
  select max(r.created_at) into v_last from kodhane_loss.loss_report r where r.user_id = uid and r.created_at > now() - interval '24 hours';
  if v_last is not null and (select count(*) from kodhane_loss.loss_report r where r.user_id = uid and r.created_at > now() - interval '24 hours') >= (cfg ->> 'per_24h')::int then
    v_at := (select min(r.created_at) from kodhane_loss.loss_report r where r.user_id = uid and r.created_at > now() - interval '24 hours') + interval '24 hours';
    raise exception using errcode = 'PT429', message = 'loss_report_daily_limit', detail = to_char(v_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;
  select count(*), min(r.created_at) into v_n30, v_first30 from kodhane_loss.loss_report r where r.user_id = uid and r.created_at > now() - interval '30 days';
  if v_n30 >= (cfg ->> 'per_30_days')::int then
    raise exception using errcode = 'PT429', message = 'loss_report_monthly_limit',
      detail = to_char((v_first30 + interval '30 days') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;
  insert into kodhane_loss.loss_report (user_id, lost_items, lost_since, description, client_version, save_revision)
  values (uid, v_items, p_lost_since, v_desc, v_cv, v_rev) returning id into v_id;
  return pg_catalog.jsonb_build_object('id', v_id, 'status', 'in_review', 'created_at', now());
end $$;

create or replace function public.kodhane_loss_report_status(p_limit integer default 10)
returns table (id bigint, created_at timestamptz, lost_items text[], lost_since timestamptz, status text,
               status_changed_at timestamptz, reason text, applied_at timestamptz, review_reason text, applied_revision bigint)
language plpgsql stable security definer set search_path = ''
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception using errcode = '42501', message = 'not_authenticated'; end if;
  return query
    select r.id, r.created_at, r.lost_items, r.lost_since,
           case r.status when 'pending' then 'in_review' when 'needs_review' then 'in_review' else r.status end,
           r.status_changed_at,
           case when r.status = 'rejected' then r.reject_reason end,
           r.applied_at,
           -- only the two codes of the CHECK, only while the player sees in_review; no note, no reference, no team field
           case when r.status = 'needs_review' and r.review_reason in ('save_changed', 'no_cloud_save') then r.review_reason end,
           -- the save revision the restore wrote (applied only): exact "this tab is older than the restore" test for the client
           case when r.status = 'applied' then r.applied_rev_after end
      from kodhane_loss.loss_report r
     where r.user_id = uid
     order by r.created_at desc, r.id desc
     limit least(greatest(coalesce(p_limit, 10), 1), 50);
end $$;

-- ---------------------------------------------------------------- owners + privileges
do $own$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_catalog.pg_proc p
            where (p.pronamespace = 'kodhane_loss'::regnamespace and (p.proname like 'loss\_report%' or p.proname in ('cfg_loss_report', 'cleanup_loss_reports')))
               or (p.pronamespace = 'public'::regnamespace and p.proname in ('kodhane_loss_report_create', 'kodhane_loss_report_status')) loop
    execute format('alter function %s owner to postgres', f);
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f);
  end loop;
end $own$;
grant execute on function public.kodhane_loss_report_create(text[], timestamptz, text, text) to authenticated;
grant execute on function public.kodhane_loss_report_status(integer) to authenticated;
comment on function public.kodhane_loss_report_create(text[], timestamptz, text, text) is
  'Kodhane "Kayıp bildir" (v4.5 P7): the signed-in player files a loss report. 1 per 24 h, 5 per 30 days, one open at a time; needs a cloud save. No e-mail.';
comment on function public.kodhane_loss_report_status(integer) is
  'Kodhane "Kayıp bildir": the caller''s own reports (in_review | approved | rejected | applied; review_reason save_changed | no_cloud_save | NULL; applied_revision = save revision written by the restore, applied only); no ops fields.';

notify pgrst, 'reload schema';
commit;
