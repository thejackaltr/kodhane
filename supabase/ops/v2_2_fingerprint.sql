-- v2.2 player-data fingerprint (READ ONLY). Same output before the migrations, after them and after the rollbacks
-- as long as no player wrote in between -> proof that real player data was not changed.
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/ops/v2_2_fingerprint.sql > fp-<phase>.txt ; diff fp-before.txt fp-<phase>.txt
-- Covers what players own and the migrations must not change: kodhane_saves, acik_ofis_saves (user_id, data, updated_at,
-- save_version) and kodhane_profiles (nicknames). New v2.2 columns/tables are deliberately NOT part of it.
-- Output: one line per table: table|rows|md5 (deterministic: UTC, ISO dates, jsonb canonical text, ordered by user_id).
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset footer off
begin read only;
set local timezone = 'UTC';
set local datestyle = 'ISO, YMD';
select 'kodhane_saves', count(*),
       md5(coalesce(string_agg(concat_ws('|', user_id, data::text, coalesce(updated_at::text, '-'), coalesce(save_version::text, '-')), E'\n' order by user_id), ''))
  from public.kodhane_saves
union all
select 'acik_ofis_saves', count(*),
       md5(coalesce(string_agg(concat_ws('|', user_id, data::text, coalesce(updated_at::text, '-'), coalesce(save_version::text, '-')), E'\n' order by user_id), ''))
  from public.acik_ofis_saves
union all
select 'kodhane_profiles', count(*),
       md5(coalesce(string_agg(concat_ws('|', user_id, nickname, hidden, coalesce(hidden_reason, '-'), created_at, updated_at), E'\n' order by user_id), ''))
  from public.kodhane_profiles;
commit;
