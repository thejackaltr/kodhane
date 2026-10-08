#!/usr/bin/env bash
# Starts a throw-away LOCAL Supabase stack (Supabase CLI, Docker: db + auth + rest + kong only), runs run_http_tests.sh
# with the stack's demo keys taken from `supabase status -o env` (kept in this process's env only, never written to a
# file or printed), then stops the stack without a backup (no volumes left). Needs docker + node/npx.
#   usage: bash supabase/tests/http/run_with_local_stack.sh        (KEEP_STACK=1 to leave it running)
# Note (box sandbox 2026-09-28): container-to-container traffic needed `iptables-legacy -I DOCKER-USER -j ACCEPT`.
# Image guard (2026-10-03): `supabase start` PULLS every stack image it does not have (db, gotrue, postgrest, kong, ...).
# Pulling new images needs explicit approval, so by default this script prints SKIP and exits 0 without starting
# anything. Run it only with ALLOW_IMAGE_PULL=1 after that approval. For package B / loss report HTTP checks without any
# pull use supabase/tests/v4_4/http_v4_4b.sh (local PostgREST image only, docker run --pull=never).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
if [[ "${ALLOW_IMAGE_PULL:-}" != 1 ]]; then
  echo "SKIP run_with_local_stack: 'supabase start' would pull Docker images; set ALLOW_IMAGE_PULL=1 only with approval. HTTP stack NOT tested."
  exit 0
fi
CLI=${SUPABASE_CLI:-"npx -y supabase@2.118.0"}
WORK=${STACK_DIR:-/tmp/v22-sbstack}
mkdir -p "$WORK"; cd "$WORK"
[[ -f supabase/config.toml ]] || { $CLI init --force >/dev/null; sed -i 's/^project_id = .*/project_id = "v22-http-test"/' supabase/config.toml; }
# start prints the local demo keys: filter every key/secret line out of the output (they stay out of logs)
$CLI start -x realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor 2>&1 \
  | grep -viE 'key|secret|jwt|eyJ|sb_|password|postgresql://|"DB_URL"' || true
$CLI status >/dev/null 2>&1 || { echo "local stack did not start"; exit 1; }
eval "$($CLI status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY|DB_URL)=')"
export API_URL ANON_KEY SERVICE_ROLE_KEY DB_URL
rc=0; bash "$HERE/run_http_tests.sh" || rc=$?
[[ "${KEEP_STACK:-}" == 1 ]] || $CLI stop --no-backup
exit $rc
