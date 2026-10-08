-- Deletion log test helpers (LOCAL THROWAWAY DB ONLY; schema t from fixtures/helpers.sql).
-- t.dl_fp(ex): md5 + count per table of every row NOT belonging to the uids in ex (other users unchanged?).
-- t.dl_user(u): row counts of one uid per table (Kodhane / Açık Ofis / auth / audit).
create or replace function t.dl_rels() returns table (rel text, col text) language sql stable as $$
  select format('%I.%I', n.nspname, c.relname), a.attname::text
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
   where c.relkind in ('r', 'p') and ((n.nspname = 'public' and (c.relname like 'kodhane\_%' or c.relname like 'acik\_ofis\_%') and a.attname = 'user_id')
      or (n.nspname = 'auth' and c.relname = 'users' and a.attname = 'id') or (n.nspname = 'auth' and a.attname = 'user_id'))
  union all select 'auth.audit_log_entries', '*audit*' $$;
create or replace function t.dl_fp(p_ex uuid[]) returns table (rel text, h text) language plpgsql as $$
declare r record; v text; w text;
begin
  for r in select * from t.dl_rels() order by 1 loop
    w := case when r.col = '*audit*' then format('not coalesce((x.payload ->> %L)::text = any (%L::text[]) or (x.payload -> %L ->> %L) = any (%L::text[]), false)', 'actor_id', p_ex, 'traits', 'user_id', p_ex)
              else format('not coalesce(x.%I::text = any (%L::text[]), false)', r.col, p_ex) end;
    execute format('select md5(coalesce(string_agg(x::text, ''|'' order by x::text), '''')) || '':'' || count(*) from %s x where %s', r.rel, w) into v;
    rel := r.rel; h := v; return next;
  end loop;
end $$;
create or replace function t.dl_user(p_uid uuid) returns table (rel text, n bigint) language plpgsql as $$
declare r record;
begin
  for r in select * from t.dl_rels() order by 1 loop
    if r.col = '*audit*' then
      execute 'select count(*) from auth.audit_log_entries x where x.payload ->> ''actor_id'' = $1 or x.payload -> ''traits'' ->> ''user_id'' = $1' into n using p_uid::text;
    else execute format('select count(*) from %s x where x.%I::text = $1', r.rel, r.col) into n using p_uid::text; end if;
    rel := r.rel; return next;
  end loop;
end $$;
