#!/usr/bin/env bash
# Kodhane v4.5 score rule: rejections BEFORE (v4.4b, package B) / AFTER (v4.5, row v45_f2 and row v45_f3) on the full
# simulation dumps (every rule check of every run: JSONL {job, i, now, sim_ok, sim_why, sim_ok_1e21, d}, written by
# kodhane-v45-skor/sim/dumprun.js from sim45.js). LOCAL THROWAWAY DATABASE ONLY (drops / creates $SR_DB in $SR_CT).
#   SR_CT=<container> SR_DUMPS=/workspace/kodhane-v45-skor/dumps bash supabase/tests/score_rule/measure_sim_dumps.sh
# Groups by job prefix: F (sim r2 candidate, Karar 1 off), F-K1 (same with Karar 1 on), F2 (sim r2 proposal, 1 seed),
# F2b (r3: F2 + Borsa dalı 6/9/12, 8 seeds / session shifts), F3 (r3 comparison H20x125, 8 seeds), B44 (v4.4 game
# without v4.5 changes, v4.4-format saves), E1off (F2b with E1 off). Each run is judged with the curve of its own game too: F3 runs
# with v45_f3, all others with v45_f2 ("own" column). Output: GROUP / WHY / FAILROW lines (pipe separated).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CT="${SR_CT:-v45-136}"; BASE="${SR_BASE:-v44_base}"; DB="${SR_DB:-sr_measure}"; DUMPS="${SR_DUMPS:-/workspace/kodhane-v45-skor/dumps}"
# since 2026-10-03 the dumps are kept as one archive: dumps.tar.zst next to the directory (md5 821299a1af1076d0bd30b589a140f8ee)
[[ -d "$DUMPS" ]] || { echo "STOP: no dump directory $DUMPS; unpack first: tar --zstd -xf ${DUMPS%/}.tar.zst -C $(dirname "$DUMPS")"; exit 1; }
MIGA="$ROOT/migrations/20260929203000_v4_4a_kodhane_score_plausible.sql"; MIGB="$ROOT/migrations/20260929204000_v4_4b_kodhane_stage_ids_version_guard.sql"
MIGS="$ROOT/migrations/20261003080000_v4_5_kodhane_score_rule.sql"
P() { docker exec -i "$CT" psql -U supabase_admin -X -q -v ON_ERROR_STOP=1 "$@"; }
P -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB template $BASE" >/dev/null || exit 1
for f in "$MIGA" "$MIGB"; do P -d $DB -1 -f - < "$f" >/dev/null || exit 1; done
awk '/create or replace function public.kodhane_score_plausible/{p=1} p{print} /^\$function\$;/{if(p){exit}}' "$MIGB" \
  | sed 's/create or replace function public.kodhane_score_plausible(/create or replace function public.kodhane_score_plausible_v44b_ref(/' | P -d $DB -f - >/dev/null || exit 1
P -d $DB -f - < "$MIGS" >/dev/null || exit 1
P -d $DB -c "create table public.sim_dump (l jsonb)" >/dev/null
n=0; for f in "$DUMPS"/*.jsonl; do
  python3 -c 'import sys, json
for l in open(sys.argv[1]):
    l = l.strip()
    if l: json.loads(l); print(l.replace(chr(92), chr(92) * 2))' "$f" | P -d $DB -c "copy public.sim_dump (l) from stdin with (format text)" || exit 1
  n=$((n+1)); done
echo "INFO|dump_files|$n|$(md5sum "$DUMPS"/*.jsonl | md5sum | cut -c1-32)"
P -At -F '|' -d $DB <<'SQL'
create table public.m as
select l ->> 'job' as job,
       case when l ->> 'job' like 'ms-F2b-%' then 'F2b' when l ->> 'job' like 'ms-F3-%' then 'F3'
            when l ->> 'job' like 'F2-%' then 'F2' when l ->> 'job' like 'F-K1-%' then 'F-K1' when l ->> 'job' like 'F-%' then 'F'
            when l ->> 'job' like 'base44-%' then 'B44' when l ->> 'job' like 'e1off-%' then 'E1off' else '?' end as grp,
       (l ->> 'i')::int as i, (l ->> 'sim_ok')::boolean as sim_ok, l ->> 'sim_why' as sim_why, (l ->> 'sim_ok_1e21')::boolean as sim_ok21,
       l -> 'd' as d, to_timestamp((l ->> 'now')::float8 / 1000) as at,
       public.kodhane_score_plausible_v44b_ref(l -> 'd', to_timestamp((l ->> 'now')::float8 / 1000)) as b_ok,
       public.kodhane_score_plausible(l -> 'd', to_timestamp((l ->> 'now')::float8 / 1000)) as f2_ok,
       null::boolean as f3_ok
  from public.sim_dump;
update kodhane_rule.score_curve set active = false;
update kodhane_rule.score_curve set active = true where id = 'v45_f3';
update public.m set f3_ok = public.kodhane_score_plausible(d, at);
update kodhane_rule.score_curve set active = false;
update kodhane_rule.score_curve set active = true where id = 'v45_f2';
select 'HEAD', 'grp', 'runs', 'checks', 'before_v44b', 'runs_with_before', 'after_v45_f2', 'after_v45_f3', 'after_own_curve', 'runs_with_after_own',
       'sql_vs_sim_mirror_mismatch', 'accepted_before_refused_after';
select 'GROUP', grp, count(distinct job), count(*), count(*) filter (where not b_ok), count(distinct job) filter (where not b_ok),
       count(*) filter (where not f2_ok), count(*) filter (where not f3_ok),
       count(*) filter (where not (case when grp = 'F3' then f3_ok else f2_ok end)),
       count(distinct job) filter (where not (case when grp = 'F3' then f3_ok else f2_ok end)),
       count(*) filter (where sim_ok <> b_ok),
       count(*) filter (where b_ok and not (case when grp = 'F3' then f3_ok else f2_ok end))
  from public.m group by rollup (grp) order by grp nulls last;
select 'WHY', grp, 'before', coalesce(split_part(sim_why, ' (', 1), '-'), count(*) from public.m where not b_ok group by 2, 4
union all
select 'WHY', grp, 'after_own', coalesce(split_part(sim_why, ' (', 1), '-'), count(*) from public.m
 where not (case when grp = 'F3' then f3_ok else f2_ok end) group by 2, 4 order by 2, 3, 4;
select 'FAILROW', job, i, sim_why from public.m where not (case when grp = 'F3' then f3_ok else f2_ok end) order by job, i;
SQL
P -d postgres -c "drop database if exists $DB with (force)" >/dev/null
