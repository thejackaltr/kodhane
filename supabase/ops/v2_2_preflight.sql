-- v2.2 preflight (READ ONLY): is this the right database? then prints the player-data fingerprint (v2_2_fingerprint.sql).
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v2_2_preflight.sql > fp-before.txt
-- The target checks go to stderr (NOTICE / ERROR); stdout is exactly the fingerprint, so it can be diffed later.
-- Fails (exit 3, nothing printed on stdout) when the database is not the shared Teserix game DB (supabase.teserix.com =
-- kodhane-api.teserix.com, same database): both save tables, kodhane_profiles, both plausibility functions and
-- kodhane_leaderboard(int, text) must exist.
\set ON_ERROR_STOP on
begin read only;
do $pre$
declare
  missing text[] := '{}';
  k22 boolean; a22 boolean; cmt text; f regprocedure := to_regprocedure('public.kodhane_leaderboard(integer,text)');
begin
  if to_regclass('public.kodhane_saves') is null then missing := array_append(missing, 'table public.kodhane_saves'); end if;
  if to_regclass('public.acik_ofis_saves') is null then missing := array_append(missing, 'table public.acik_ofis_saves'); end if;
  if to_regclass('public.kodhane_profiles') is null then missing := array_append(missing, 'table public.kodhane_profiles'); end if;
  if to_regprocedure('public.kodhane_score_plausible(jsonb,timestamptz)') is null then missing := array_append(missing, 'function kodhane_score_plausible'); end if;
  if to_regprocedure('public.acik_ofis_score_plausible(jsonb,timestamptz)') is null then missing := array_append(missing, 'function acik_ofis_score_plausible'); end if;
  if f is null then missing := array_append(missing, 'function kodhane_leaderboard(int, text)'); end if;
  if cardinality(missing) > 0 then
    raise exception 'WRONG TARGET: this is not the shared Teserix game DB (missing: %). Do not apply the v2.2 files here.', array_to_string(missing, ', ');
  end if;
  k22 := exists (select 1 from pg_attribute where attrelid = 'public.kodhane_saves'::regclass and attname = 'best_score' and not attisdropped);
  a22 := exists (select 1 from pg_attribute where attrelid = 'public.acik_ofis_saves'::regclass and attname = 'best_score' and not attisdropped);
  cmt := coalesce(obj_description(f, 'pg_proc'), '');
  raise notice 'target ok: db=%, user=%, kodhane_saves=% rows, acik_ofis_saves=% rows, kodhane_profiles=% rows',
    current_database(), current_user, (select count(*) from public.kodhane_saves), (select count(*) from public.acik_ofis_saves),
    (select count(*) from public.kodhane_profiles);
  raise notice 'v2.2 state: kodhane %, acik_ofis %, kodhane_leaderboard %',
    case when k22 then 'ALREADY APPLIED' else 'not applied (expected)' end,
    case when a22 then 'ALREADY APPLIED' else 'not applied (expected)' end,
    case when cmt like '%v6 (Kodhane v2.2 migration 20260928160000)%' then 'v6'
         when cmt like '%Açık Ofis v2.2 shim%' then 'v5 + Açık Ofis shim'
         else 'v5 (expected before v2.2)' end;
end $pre$;
commit;
\ir v2_2_fingerprint.sql
