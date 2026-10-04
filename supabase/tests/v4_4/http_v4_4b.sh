#!/usr/bin/env bash
# HTTP layer for package B: a throwaway PostgREST container on the LOCAL test DB (in the network namespace of $1, no published
# port: curl talks to the DB container's IP, so an --internal network works and no container-to-container traffic is needed; random JWT secret, local-only authenticator password).
# Uses only a LOCAL image (docker run --pull=never): if $V44_PGRST_IMAGE is not present, prints SKIP and exits 0
# (the caller reports SKIP, not PASS); nothing is pulled. Checks the client-visible contract:
# PT426 -> HTTP 426 {code: PT426, message: save_version_too_old}; PT409 stays 409; kodhane_leaderboard_v7 over HTTP.
#   bash http_v4_4b.sh <db container> <db name>
set -uo pipefail
CT=$1; DB=$2; IMG="${V44_PGRST_IMAGE:-public.ecr.aws/supabase/postgrest:v16.3}"; PORT="${V44_PGRST_PORT:-39444}"
HOST=$(docker inspect "$CT" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))'); PW=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
U1=11111111-1111-4111-8111-111111111111; NAME=v44b-pgrst-$$
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "SKIP HTTP: PostgREST image $IMG is not present locally; not pulled (docker run --pull=never). HTTP layer NOT tested."; exit 0
fi
docker exec -i "$CT" psql -U supabase_admin -X -q -d "$DB" -c "alter role authenticator with login password '$PW'" >/dev/null
docker run -d --rm --pull=never --name "$NAME" --network "container:$CT" \
  -e PGRST_DB_URI="postgres://authenticator:$PW@127.0.0.1:5432/$DB" -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET="$SECRET" -e PGRST_SERVER_PORT=$PORT "$IMG" >/dev/null || { echo "FAIL H0 PostgREST container did not start ($IMG)"; exit 1; }
trap 'docker rm -f "$NAME" >/dev/null 2>&1; docker exec -i "$CT" psql -U supabase_admin -X -q -d "$DB" -c "alter role authenticator with password null" >/dev/null 2>&1' EXIT
jwt() { python3 - "$SECRET" "$1" "$2" <<'PY'
import base64, hashlib, hmac, json, sys, time
b = lambda x: base64.urlsafe_b64encode(json.dumps(x, separators=(',', ':')).encode()).rstrip(b'=')
h, p = b({'alg': 'HS256', 'typ': 'JWT'}), b({'role': sys.argv[2], 'sub': sys.argv[3], 'exp': int(time.time()) + 600})
s = base64.urlsafe_b64encode(hmac.new(sys.argv[1].encode(), h + b'.' + p, hashlib.sha256).digest()).rstrip(b'=')
print((h + b'.' + p + b'.' + s).decode())
PY
}
TOK=$(jwt authenticated $U1)
BASE="http://$HOST:$PORT"   # PostgREST shares the DB container's network namespace
for i in $(seq 1 40); do curl -s -o /dev/null "$BASE/" && break; sleep 0.5; done
api() { curl -s -o /tmp/v44b-http-body.$$ -w '%{http_code}' -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$@"; }
ok() { if [[ "$2" == 1 ]]; then echo "PASS $1 ${3:+ -- $3}"; else echo "FAIL $1 ${3:+ -- $3}"; fi; }
rev=$(docker exec -i "$CT" psql -U supabase_admin -X -At -d "$DB" -c "select revision from public.kodhane_saves where user_id = '$U1'")
sv=$(docker exec -i "$CT" psql -U supabase_admin -X -At -d "$DB" -c "select coalesce(data->>'saveVersion','0') from public.kodhane_saves where user_id = '$U1'")
now=$(python3 -c 'import time; print(int(time.time()*1000))')
row() { echo "{\"user_id\":\"$U1\",\"data\":{\"version\":$1,$2\"totalEarned\":5000,\"runEarned\":5000,\"cycleEarned\":5000,\"startedAt\":$((now-3600000)),\"lastSaved\":$now},\"save_version\":$1,\"updated_at\":\"2026-09-29T18:00:00Z\",\"revision\":$3}"; }
UP=(-X POST "$BASE/kodhane_saves?on_conflict=user_id&select=revision" -H 'Prefer: resolution=merge-duplicates,return=representation')
c=$(api "${UP[@]}" -d "$(row 7 '"saveVersion":7,' $((rev+1)))"); ok "H1 v4.4-style upsert (saveVersion 7 >= stored $sv) -> 2xx" "$([[ $c == 20* ]] && echo 1)" "HTTP $c"
c=$(api "${UP[@]}" -d "$(row 4 '' $((rev+2)))"); body=$(cat /tmp/v44b-http-body.$$)
ok "H2 v4.3.0-style upsert (no saveVersion) over saveVersion 7 -> HTTP 426" "$([[ $c == 426 ]] && echo 1)" "HTTP $c"
ok "H3 426 body: code PT426, message save_version_too_old, details name both versions" \
  "$(python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(1 if j.get("code")=="PT426" and j.get("message")=="save_version_too_old" and "stored saveVersion 7" in (j.get("details") or "") else 0)' "$body")" "$body"
c=$(api "${UP[@]}" -d "$(row 4 '"saveVersion":4,' $((rev+2)))"); ok "H4 v4.3.1-style upsert (saveVersion 4) over 7 -> HTTP 426" "$([[ $c == 426 ]] && echo 1)" "HTTP $c"
c=$(api "${UP[@]}" -d "$(row 7 '"saveVersion":7,' $rev)"); ok "H5 stale revision, same version -> HTTP 409 (v2.2 contract unchanged)" "$([[ $c == 409 ]] && echo 1)" "HTTP $c $(cat /tmp/v44b-http-body.$$ | head -c 80)"
c=$(api -X POST "$BASE/rpc/kodhane_leaderboard_v7" -d '{"p_limit":5}'); b=$(cat /tmp/v44b-http-body.$$)
ok "H6 rpc/kodhane_leaderboard_v7 -> 200, rows carry stage_id" "$([[ $c == 200 ]] && python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(1 if j and all("stage_id" in r for r in j) else 0)' "$b")" "HTTP $c, $(echo "$b" | head -c 120)"
c=$(api -X POST "$BASE/rpc/kodhane_leaderboard" -d '{"p_limit":5,"p_game":"acik_ofis"}'); b=$(cat /tmp/v44b-http-body.$$)
ok "H7 rpc/kodhane_leaderboard acik_ofis -> 200, v6 keys only (no stage_id)" "$([[ $c == 200 ]] && python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(1 if all(set(r)=={"rank","nickname","score","stage","is_me","status"} for r in j) else 0)' "$b")" "HTTP $c, $(echo "$b" | head -c 120)"
rm -f /tmp/v44b-http-body.$$
