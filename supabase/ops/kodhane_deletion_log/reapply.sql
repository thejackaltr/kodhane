-- Kodhane deletion log reapply / verify, main part (used by ops/kodhane_deletion_log_reapply.sh; the script generates,
-- in ONE transaction: psql prefix, begin, pg_temp.dl_in (the export files' rows, validated in the script), the functions
-- pg_temp.kodhane_del_run() = the DO block of ops/kodhane_account_delete.sql verbatim and pg_temp.kodhane_dl_counts(uuid)
-- (o_cat, o_rel, o_n) = its <kodhane_del_counts> block verbatim, set_config('kodhane_dl.mode', reapply | verify), this file, then commit
-- (reapply) or rollback (verify, dryrun)).
-- Entries = union of the files and the DB list (uid, scope; earliest deleted_at). Per entry (pg_temp.kodhane_dl_state):
--   account  auth user present            -> 'account'  reapply: the full delete (kodhane_account_delete.sql DO block)
--            no auth user, counts (pg_temp.kodhane_dl_counts) show audit rows only -> 'audit'  reapply: those audit rows
--            no auth user, other rows of the uid in the counts -> 'orphan'  reapply STOPS (rolled back), verify LEFT
--            nothing                       -> 'nothing'
--   kodhane  no auth user                  -> 'nothing'  (account gone; its rows went with it)
--            Kodhane rows only from BEFORE deleted_at          -> 'kodhane' reapply: the kodhane_only delete
--            Kodhane rows only from AFTER deleted_at           -> 'newer'   kept (played again after the deletion)
--            both                                              -> 'mixed'   NOT deleted, reported: Aryen decides
--            (before / after: kodhane_saves.updated_at, kodhane_save_backups.created_at, kodhane_progress_log.created_at;
--             kodhane_event_log_carry rows count as before)
--            none                                              -> 'nothing'
-- Any row outside Kodhane / Açık Ofis / auth (act_full = block) stops the full delete -> the whole run rolls back.
create temp table dl_out (id serial, line text) on commit drop;
create or replace function pg_temp.kodhane_dl_state(p_uid uuid, p_scope text, p_at timestamptz) returns text language plpgsql as $f$
declare v_old bigint := 0; v_new bigint := 0; n bigint; m bigint; v_total bigint; v_audit bigint;
begin
  if p_scope = 'account' then
    if exists (select 1 from auth.users u where u.id = p_uid) then return 'account'; end if;
    select coalesce(sum(x.o_n), 0), coalesce(sum(x.o_n) filter (where x.o_rel = 'auth.audit_log_entries'), 0) into v_total, v_audit
      from pg_temp.kodhane_dl_counts(p_uid) x;
    return case when v_total = 0 then 'nothing' when v_total = v_audit then 'audit' else 'orphan' end;
  end if;
  if not exists (select 1 from auth.users u where u.id = p_uid) then return 'nothing'; end if;
  select count(*) filter (where s.updated_at < p_at), count(*) filter (where s.updated_at >= p_at) into n, m
    from public.kodhane_saves s where s.user_id = p_uid;
  v_old := v_old + n; v_new := v_new + m;
  select count(*) filter (where b.created_at < p_at), count(*) filter (where b.created_at >= p_at) into n, m
    from public.kodhane_save_backups b where b.user_id = p_uid;
  v_old := v_old + n; v_new := v_new + m;
  if to_regclass('public.kodhane_progress_log') is not null then
    execute 'select count(*) filter (where created_at < $2), count(*) filter (where created_at >= $2) from public.kodhane_progress_log where user_id = $1'
      into n, m using p_uid, p_at;
    v_old := v_old + n; v_new := v_new + m;
  end if;
  if to_regclass('public.kodhane_event_log_carry') is not null
     and exists (select 1 from pg_catalog.pg_attribute a where a.attrelid = to_regclass('public.kodhane_event_log_carry') and a.attname = 'user_id' and not a.attisdropped) then
    execute 'select count(*) from public.kodhane_event_log_carry where user_id = $1' into n using p_uid;
    v_old := v_old + n;
  end if;
  return case when v_old > 0 and v_new > 0 then 'mixed' when v_old > 0 then 'kodhane' when v_new > 0 then 'newer' else 'nothing' end;
end $f$;
do $re$
declare
  v_mode text := current_setting('kodhane_dl.mode');
  r record; v_state text; v_bad text; v_left text; v_mixed text; n bigint;
  n_files bigint; n_entries bigint := 0; n_new bigint := 0; n_missing bigint := 0;
  c jsonb := '{"account": 0, "audit": 0, "orphan": 0, "kodhane": 0, "newer": 0, "mixed": 0, "nothing": 0}';
begin
  if v_mode not in ('reapply', 'verify') then raise exception 'kodhane deletion log: unknown mode %', v_mode; end if;
  if to_regclass('public.kodhane_saves') is null or to_regclass('auth.users') is null then
    raise exception 'kodhane deletion log %: wrong target (public.kodhane_saves / auth.users missing in database %)', v_mode, current_database();
  end if;
  if to_regclass('public.fenomen_saves') is not null then
    raise exception 'kodhane deletion log %: wrong target (public.fenomen_saves exists)', v_mode;
  end if;
  if to_regclass('kodhane_private.deletion_log') is null then
    raise exception 'kodhane deletion log %: kodhane_private.deletion_log missing (install migration 20261003040000 first, separate step); nothing changed', v_mode;
  end if;
  -- second check of the file rows (the script checked the format already)
  select string_agg(i.user_id || '/' || coalesce(i.scope, '?'), ', ') into v_bad from pg_temp.dl_in i
   where i.user_id is null or i.scope is null or i.scope not in ('account', 'kodhane') or i.deleted_at is null
      or i.deleted_at > now() + interval '5 minutes' or i.approval_ref is null
      or i.approval_ref !~ '^(self|info|purge):[^@,"\\[:cntrl:]]{1,200}$';
  if v_bad is not null then raise exception 'kodhane deletion log %: invalid file rows (%); nothing changed', v_mode, v_bad; end if;
  select count(*) into n_files from pg_temp.dl_in;
  select count(*) into n_missing from (select distinct i.user_id, i.scope from pg_temp.dl_in i) i
   where not exists (select 1 from kodhane_private.deletion_log d where d.user_id = i.user_id and d.scope = i.scope);
  if v_mode = 'reapply' then
    insert into kodhane_private.deletion_log (user_id, scope, deleted_at, approval_ref)
    select distinct on (i.user_id, i.scope) i.user_id, i.scope, i.deleted_at, i.approval_ref
      from pg_temp.dl_in i order by i.user_id, i.scope, i.deleted_at, i.approval_ref
    on conflict (user_id, scope) do nothing;
    get diagnostics n_new = row_count;
  end if;
  for r in
    select e.user_id, e.scope, min(e.deleted_at) as at,
           coalesce((select d.approval_ref from kodhane_private.deletion_log d where d.user_id = e.user_id and d.scope = e.scope),
                    min(e.approval_ref)) as ref
      from (select i.user_id, i.scope, i.deleted_at, i.approval_ref from pg_temp.dl_in i
            union all
            select d.user_id, d.scope, d.deleted_at, d.approval_ref from kodhane_private.deletion_log d) e
     group by e.user_id, e.scope
     order by case e.scope when 'account' then 0 else 1 end, min(e.deleted_at), e.user_id
  loop
    n_entries := n_entries + 1;
    v_state := pg_temp.kodhane_dl_state(r.user_id, r.scope, r.at);
    c := jsonb_set(c, array[v_state], to_jsonb((c ->> v_state)::bigint + 1));
    if v_mode = 'reapply' and v_state in ('account', 'kodhane') then
      perform set_config('kodhane_del.uid', r.user_id::text, true), set_config('kodhane_del.confirm_uid', r.user_id::text, true),
              set_config('kodhane_del.mode', case v_state when 'account' then 'full' else 'kodhane_only' end, true),
              set_config('kodhane_del.approval_ref', r.ref, true), set_config('kodhane_del.expect', '', true),
              set_config('kodhane_del.reapply', 'on', true);
      perform pg_temp.kodhane_del_run();
      perform set_config('kodhane_del.reapply', 'off', true);
    elsif v_mode = 'reapply' and v_state = 'audit' then
      delete from auth.audit_log_entries e
       where e.payload ->> 'actor_id' = r.user_id::text or e.payload -> 'traits' ->> 'user_id' = r.user_id::text;
    end if;
    if v_mode = 'reapply' and v_state = 'orphan' then
      raise exception 'kodhane deletion log reapply BLOCKED: rows of deleted account % without its auth user (see the verify); rolled back', r.user_id;
    end if;
    if v_state in ('account', 'audit', 'orphan', 'kodhane', 'mixed') then
      insert into dl_out (line) values ('ENTRY|' || r.user_id || '|' || r.scope || '|' || v_state || '|' ||
        case v_mode when 'verify' then case v_state when 'mixed' then 'MIXED: Kodhane rows from before AND after the deletion; not deleted, Aryen decides' else 'LEFT' end
                    else case v_state when 'mixed' then 'MIXED: Kodhane rows from before AND after the deletion; not deleted, Aryen decides' else 'deleted again' end end);
    elsif v_state = 'newer' then
      insert into dl_out (line) values ('ENTRY|' || r.user_id || '|' || r.scope || '|newer|kept: Kodhane data only from after the deletion (played again)');
    end if;
  end loop;
  -- after the reapply (and in verify): nothing that should be gone may be left
  select string_agg(x.user_id || '/' || x.scope || '=' || x.st, ', ') filter (where x.st in ('account', 'audit', 'orphan', 'kodhane')),
         string_agg(x.user_id || '/' || x.scope, ', ') filter (where x.st = 'mixed')
    into v_left, v_mixed
    from (select e.user_id, e.scope, pg_temp.kodhane_dl_state(e.user_id, e.scope, min(e.deleted_at)) as st
            from (select i.user_id, i.scope, i.deleted_at from pg_temp.dl_in i
                  union all select d.user_id, d.scope, d.deleted_at from kodhane_private.deletion_log d) e
           group by e.user_id, e.scope) x;
  if v_mode = 'reapply' and v_left is not null then
    raise exception 'kodhane deletion log reapply: rows left after the reapply (%); rolled back', v_left;
  end if;
  insert into dl_out (line) values (upper(v_mode) || '|file_rows|' || n_files || '|entries|' || n_entries
    || '|list_rows_added|' || n_new || '|list_rows_missing_before|' || n_missing
    || '|account|' || (c ->> 'account') || '|audit|' || (c ->> 'audit') || '|orphan|' || (c ->> 'orphan') || '|kodhane|' || (c ->> 'kodhane')
    || '|newer|' || (c ->> 'newer') || '|mixed|' || (c ->> 'mixed') || '|nothing|' || (c ->> 'nothing'));
  insert into dl_out (line) values (upper(v_mode) || '|left|' || coalesce(v_left, '0') || '|mixed|' || coalesce(v_mixed, '0'));
end $re$;
select line from dl_out order by id;
