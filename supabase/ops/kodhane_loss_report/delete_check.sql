-- PARTIAL of supabase/ops/kodhane_loss_report_install.sh (build -> sql/delete_check.sql; run by the verify step).
-- Account deletion removes the player's Kayıp bildir reports on THIS database, as behaviour (not only the catalog line of
-- delete_path). ONE transaction that ends with ROLLBACK (the generator adds begin / rollback); nothing stays, the only
-- lasting trace is that the identity sequence of kodhane_loss.loss_report moves on by a few numbers.
-- The generator puts in front: pg_temp.kodhane_del_run() = the DO block of $KODHANE_ACCOUNT_DELETE_DIR/kodhane_account_delete.sql
-- VERBATIM (the same file the delete-script check pinned by md5), so the real delete of install day is what runs here.
-- Two synthetic auth users (ids a7a70000-...-d1e01 / -d1e02, no save, no profile): d1e01 has an open report and a closed
-- one 13 months old, d1e02 (bystander) one open report. Each check runs in its own subtransaction that is always undone.
--   1 mode kodhane_only (real DO block, expect token of the moment): d1e01 reports -> 0, auth user kept, others untouched
--   2 mode full (real DO block): d1e01 reports -> 0, auth user gone, others untouched
--   3 auth user deleted directly (GoTrue admin delete / dashboard): FK ON DELETE CASCADE -> 0, others untouched
--   4 retention + delete together: cleanup_loss_reports() takes only the 13-month-old closed report, then kodhane_only
--     takes the rest; bystander untouched (the 12-month cleanup and the account delete do not get in each other's way)
--   5 after the undone checks: d1e01 has its 2 reports again, d1e02 its 1 (subtransactions really undone)
-- Prints CHECK|delcheck_<n>|t|f|... and DELCHECK|PASS|<n> or DELCHECK|FAIL|<failed>.
select set_config('kd_lr.uid', 'a7a70000-0000-4000-8000-0000000d1e01', true) is null
    or set_config('kd_lr.uid2', 'a7a70000-0000-4000-8000-0000000d1e02', true) is null;
create temp table _kd_lr_del (n int, name text, ok boolean, info text) on commit drop;
do $g$
begin
  if exists (select 1 from auth.users u where u.id in (current_setting('kd_lr.uid')::uuid, current_setting('kd_lr.uid2')::uuid))
     or exists (select 1 from kodhane_loss.loss_report r where r.user_id in (current_setting('kd_lr.uid')::uuid, current_setting('kd_lr.uid2')::uuid)) then
    raise exception 'STOP: synthetic delete-check uid already exists on this database; nothing done';
  end if;
end $g$;
insert into auth.users (id, aud, role, created_at, updated_at)
values (current_setting('kd_lr.uid')::uuid, 'authenticated', 'authenticated', now(), now()),
       (current_setting('kd_lr.uid2')::uuid, 'authenticated', 'authenticated', now(), now());
insert into kodhane_loss.loss_report (user_id, lost_items, created_at, status, status_changed_at, reject_reason)
values (current_setting('kd_lr.uid')::uuid, '{diger}', now() - interval '400 days', 'rejected', now() - interval '13 months', 'diger');
insert into kodhane_loss.loss_report (user_id, lost_items, client_version) values
  (current_setting('kd_lr.uid')::uuid, '{agac}', 'lr-delcheck'),
  (current_setting('kd_lr.uid2')::uuid, '{diger}', 'lr-delcheck');
do $kd_lr$
declare
  v_uid uuid := current_setting('kd_lr.uid')::uuid; v_uid2 uuid := current_setting('kd_lr.uid2')::uuid;
  v_before bigint; v_after bigint; v_user boolean; v_cleanup integer; v_o0 text; v_o1 text; v_err text; v_tok text; v_msg text; v_case text;
begin
  select count(*) into v_before from kodhane_loss.loss_report where user_id = v_uid;
  select count(*) || ':' || md5(coalesce(string_agg(md5(r::text), E'\n' order by r.id), '')) into v_o0
    from kodhane_loss.loss_report r where r.user_id <> v_uid;
  foreach v_case in array array['kodhane_only', 'full', 'auth_user', 'cleanup_then_kodhane_only'] loop
    v_err := null; v_after := null; v_o1 := null; v_user := null; v_cleanup := null; v_tok := null; v_msg := null;
    begin
      if v_case = 'auth_user' then
        delete from auth.users u where u.id = v_uid;                            -- GoTrue admin delete / dashboard
      else
        if v_case = 'cleanup_then_kodhane_only' then
          v_cleanup := kodhane_loss.cleanup_loss_reports();                     -- the daily retention step
          if exists (select 1 from kodhane_loss.loss_report where user_id = v_uid and status = 'rejected') then
            raise exception 'cleanup_loss_reports() left the 13-month-old closed report';
          end if;
        end if;
        perform set_config('kodhane_del.uid', v_uid::text, true), set_config('kodhane_del.confirm_uid', v_uid::text, true),
                set_config('kodhane_del.mode', case v_case when 'full' then 'full' else 'kodhane_only' end, true),
                set_config('kodhane_del.approval_ref', 'LR-VERIFY-DELETE-CHECK', true), set_config('kodhane_del.reapply', '', true),
                set_config('kodhane_del.expect', 'probe', true);
        begin   -- a wrong token first: the real block refuses before any delete and names the token of the moment
          perform pg_temp.kodhane_del_run();
        exception when others then v_msg := sqlerrm;
        end;
        v_tok := substring(v_msg from 'now ([0-9a-f]{12})\)');
        if v_tok is null then raise exception 'no expect token from the delete block: %', left(coalesce(v_msg, 'no error'), 300); end if;
        perform set_config('kodhane_del.expect', v_tok, true);
        perform pg_temp.kodhane_del_run();                                      -- = ops/kodhane_account_delete.sql
      end if;
      select count(*) into v_after from kodhane_loss.loss_report where user_id = v_uid;
      select exists (select 1 from auth.users u where u.id = v_uid) into v_user;
      select count(*) || ':' || md5(coalesce(string_agg(md5(r::text), E'\n' order by r.id), '')) into v_o1
        from kodhane_loss.loss_report r where r.user_id <> v_uid
         and (v_case <> 'cleanup_then_kodhane_only' or r.user_id = v_uid2);   -- the cleanup may also take real closed reports > 12 months: bystander only
      raise exception using errcode = 'P0K45', message = 'undo';
    exception
      when sqlstate 'P0K45' then null;
      when others then v_err := sqlstate || ' ' || sqlerrm;
    end;
    insert into _kd_lr_del select
      case v_case when 'kodhane_only' then 1 when 'full' then 2 when 'auth_user' then 3 else 4 end,
      case v_case
        when 'kodhane_only' then 'account delete mode kodhane_only (real DO block): the player''s reports -> 0, auth user kept, other reports untouched (undone)'
        when 'full' then 'account delete mode full (real DO block): the player''s reports -> 0, auth user gone, other reports untouched (undone)'
        when 'auth_user' then 'auth user deleted directly (GoTrue admin delete): FK ON DELETE CASCADE -> 0, other reports untouched (undone)'
        else 'cleanup_loss_reports() then kodhane_only delete: cleanup takes the 13-month-old closed report, the delete the rest, bystander untouched (undone)' end,
      v_err is null and v_before = 2 and v_after = 0
        and v_user = (v_case in ('kodhane_only', 'cleanup_then_kodhane_only'))
        and case when v_case = 'cleanup_then_kodhane_only' then v_cleanup >= 1 and v_o1 = (select count(*) || ':' || md5(coalesce(string_agg(md5(r::text), E'\n' order by r.id), ''))
                                                                                          from kodhane_loss.loss_report r where r.user_id = v_uid2)
                 else v_o1 = v_o0 end,
      'reports ' || v_before || ' -> ' || coalesce(v_after::text, '?') || '; auth user ' || coalesce(v_user::text, '?')
        || coalesce('; cleanup ' || v_cleanup, '') || coalesce('; ERROR ' || v_err, '');
  end loop;
end $kd_lr$;
insert into _kd_lr_del
  select 5, 'after the undone checks: the synthetic reports are back (2 + 1), auth users back (subtransactions really undone)',
         (select count(*) from kodhane_loss.loss_report where user_id = current_setting('kd_lr.uid')::uuid) = 2
         and (select count(*) from kodhane_loss.loss_report where user_id = current_setting('kd_lr.uid2')::uuid) = 1
         and (select count(*) from auth.users where id in (current_setting('kd_lr.uid')::uuid, current_setting('kd_lr.uid2')::uuid)) = 2,
         (select count(*) from kodhane_loss.loss_report where user_id = current_setting('kd_lr.uid')::uuid) || ' + '
           || (select count(*) from kodhane_loss.loss_report where user_id = current_setting('kd_lr.uid2')::uuid) || ' reports';
select concat_ws('|', 'CHECK', 'delcheck_' || n, case when coalesce(ok, false) then 't' else 'f' end, name, info) from _kd_lr_del order by n;
select concat_ws('|', 'DELCHECK', case when bool_and(coalesce(ok, false)) and count(*) = 5 then 'PASS' else 'FAIL' end,
                 case when bool_and(coalesce(ok, false)) and count(*) = 5 then count(*)::text
                      else coalesce(string_agg('delcheck_' || n, ',' order by n) filter (where not coalesce(ok, false)), 'count ' || count(*)) end)
  from _kd_lr_del;
