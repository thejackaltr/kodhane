#!/usr/bin/env bash
# HTTP layer for the loss report RPCs (migration 20261003060000): a throwaway PostgREST container on the LOCAL test DB
# $2 in container $1 (its network namespace, no published port: curl talks to the DB container's IP, so an --internal
# network works and no container-to-container traffic is needed; random JWT secret, local-only authenticator password, reset at the end). Uses only a LOCAL image
# (docker run --pull=never): if $LR_PGRST_IMAGE is not present, prints SKIP and exits 0; nothing is pulled.
# Checks the status codes and bodies the client maps (docs/kodhane-v4.5-kayip-bildir-istemci-notu.md):
# 401 anon, 400 loss_report_invalid + details, 404 no_cloud_save, 409 loss_report_open, 429 daily / monthly + retry time,
# status RPC columns, 409 stale_revision of an old tab after a restore. Needs the loss report test fixture (schema t).
#   bash http_loss_report.sh <db container> <db name>
set -uo pipefail
CT=$1; DB=$2; IMG="${LR_PGRST_IMAGE:-public.ecr.aws/supabase/postgrest:v16.3}"; PORT="${LR_PGRST_PORT:-39444}"
U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222; U5=55555555-5555-4555-8555-555555555555
NAME=lr-pgrst-$$; BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "SKIP HTTP: PostgREST image $IMG is not present locally; not pulled (docker run --pull=never). HTTP layer NOT tested."; exit 0
fi
Q() { docker exec -i "$CT" psql -U supabase_admin -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
HOST=$(docker inspect "$CT" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))'); PW=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
Q -c "alter role authenticator with login password '$PW'" >/dev/null
docker run -d --rm --pull=never --name "$NAME" --network "container:$CT" \
  -e PGRST_DB_URI="postgres://authenticator:$PW@127.0.0.1:5432/$DB" -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET="$SECRET" -e PGRST_SERVER_PORT=$PORT "$IMG" >/dev/null || { echo "FAIL L0 PostgREST container did not start ($IMG)"; exit 1; }
trap 'docker rm -f "$NAME" >/dev/null 2>&1; Q -c "alter role authenticator with password null" >/dev/null 2>&1; rm -f "$BODY"' EXIT
jwt() { python3 - "$SECRET" "$1" <<'PY'
import base64, hashlib, hmac, json, sys, time
b = lambda x: base64.urlsafe_b64encode(json.dumps(x, separators=(',', ':')).encode()).rstrip(b'=')
h, p = b({'alg': 'HS256', 'typ': 'JWT'}), b({'role': 'authenticated', 'sub': sys.argv[2], 'exp': int(time.time()) + 600})
s = base64.urlsafe_b64encode(hmac.new(sys.argv[1].encode(), h + b'.' + p, hashlib.sha256).digest()).rstrip(b'=')
print((h + b'.' + p + b'.' + s).decode())
PY
}
# jwtp <payload json>: HS256 token with exactly these claims (+ exp), e.g. the anon key or an authenticated token without sub
jwtp() { python3 - "$SECRET" "$1" <<'PY'
import base64, hashlib, hmac, json, sys, time
b = lambda x: base64.urlsafe_b64encode(json.dumps(x, separators=(',', ':')).encode()).rstrip(b'=')
p = json.loads(sys.argv[2]); p['exp'] = int(time.time()) + 600
h, p = b({'alg': 'HS256', 'typ': 'JWT'}), b(p)
s = base64.urlsafe_b64encode(hmac.new(sys.argv[1].encode(), h + b'.' + p, hashlib.sha256).digest()).rstrip(b'=')
print((h + b'.' + p + b'.' + s).decode())
PY
}
BASE="http://$HOST:$PORT"   # PostgREST shares the DB container's network namespace
# ready = answers AND its schema cache is loaded (503 PGRST002 while loading; newer binaries listen before that)
for i in $(seq 1 40); do c=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/"); [[ $c != 000 && $c != 503 ]] && break; sleep 0.5; done
# apit <token> <path> <json>: same as api with an explicit bearer token
apit() { curl -s -o "$BODY" -w '%{http_code}' -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -X POST "$BASE/$2" -d "$3"; }
# api <uid | anon> <path> <json>: prints the HTTP status, body in $BODY
api() { local a=(); [[ $1 != anon ]] && a=(-H "Authorization: Bearer $(jwt "$1")")
  curl -s -o "$BODY" -w '%{http_code}' "${a[@]}" -H 'Content-Type: application/json' -X POST "$BASE/$2" -d "$3"; }
ok() { if [[ "$2" == 1 ]]; then echo "PASS $1 ${3:+ -- ${3:0:160}}"; else echo "FAIL $1 ${3:+ -- ${3:0:300}}"; fi; }
# err body: code|message|details
eb() { python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print("|".join(str(j.get(k)) for k in ("code","message","details")))' "$BODY"; }
CR=rpc/kodhane_loss_report_create
iso() { python3 -c "import datetime as d, sys; print((d.datetime.now(d.timezone.utc) + d.timedelta(seconds=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" "$1"; }
# start of today in UTC+14 (Pacific/Kiritimati) as the client sends it
K14=$(python3 -c "import datetime as d; z=d.timezone(d.timedelta(hours=14)); n=d.datetime.now(z); print(n.replace(hour=0,minute=0,second=0,microsecond=0).astimezone(d.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")
Q -c "delete from kodhane_loss.loss_report" >/dev/null

c=$(api anon $CR '{"p_lost_items":["diger"]}'); ok "L1 anon (no JWT) -> 401" "$([[ $c == 401 ]] && echo 1)" "HTTP $c $(cat "$BODY")"
ANONKEY=$(jwtp '{"iss": "supabase", "role": "anon"}'); NOSUB=$(jwtp '{"iss": "supabase", "role": "authenticated", "aud": "authenticated"}')
c=$(apit "$ANONKEY" $CR '{"p_lost_items":["diger"]}'); r1="$c $(eb)"
c=$(apit "$ANONKEY" rpc/kodhane_loss_report_status '{}'); r2="$c $(eb)"
ok "L1b anon key as bearer (role anon JWT, what supabase-js sends without a session) -> create + status: 401 42501 permission denied (anon has no EXECUTE)" \
  "$([[ $r1 == '401 42501|permission denied for function kodhane_loss_report_create|None' && $r2 == '401 42501|permission denied for function kodhane_loss_report_status|None' ]] && echo 1)" "create $r1, status $r2"
c=$(apit "$NOSUB" $CR '{"p_lost_items":["diger"]}'); r1="$c $(eb)"
c=$(apit "$NOSUB" rpc/kodhane_loss_report_status '{}'); r2="$c $(eb)"
ok "L1c authenticated JWT without sub (no user id) -> create + status: 403 42501 not_authenticated" \
  "$([[ $r1 == '403 42501|not_authenticated|None' && $r2 == '403 42501|not_authenticated|None' ]] && echo 1)" "create $r1, status $r2"
c=$(api $U2 $CR '{"p_lost_items":["para"]}'); ok "L2 unknown lost_items -> 400 22023 loss_report_invalid, details lost_items" "$([[ $c == 400 && $(eb) == '22023|loss_report_invalid|lost_items' ]] && echo 1)" "HTTP $c $(eb)"
c=$(api $U2 $CR "{\"p_lost_items\":[\"diger\"],\"p_lost_since\":\"$(iso 3600)\"}"); ok "L3 lost_since 1 h ahead -> 400, details lost_since" "$([[ $c == 400 && $(eb) == '22023|loss_report_invalid|lost_since' ]] && echo 1)" "HTTP $c $(eb)"
c=$(api $U2 $CR "{\"p_lost_items\":[\"diger\"],\"p_description\":\"$(printf 'a%.0s' {1..281})\"}"); ok "L3b description 281 characters -> 400, details description" "$([[ $c == 400 && $(eb) == '22023|loss_report_invalid|description' ]] && echo 1)" "HTTP $c $(eb)"
c=$(api $U5 $CR '{"p_lost_items":["diger"]}'); ok "L4 no cloud save -> 404 PT404 no_cloud_save" "$([[ $c == 404 && $(eb) == PT404\|no_cloud_save\|* ]] && echo 1)" "HTTP $c $(eb)"
c=$(api $U2 $CR "{\"p_lost_items\":[\"borsa_payi\",\"agac\"],\"p_lost_since\":\"$K14\",\"p_description\":\"$(printf 'b%.0s' {1..280})\",\"p_client_version\":\"4.5.0\"}"); b=$(cat "$BODY")
ok "L5 valid (Bugün in UTC+14 = $K14, description 280) -> 200 {id, status in_review, created_at}" \
  "$([[ $c == 200 ]] && python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(1 if set(j)=={"id","status","created_at"} and j["status"]=="in_review" and isinstance(j["id"],int) else 0)' "$b")" "HTTP $c $b"
RID=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",0))' "$b" 2>/dev/null || echo 0)
c=$(api $U2 $CR '{"p_lost_items":["diger"],"p_lost_since":null}'); ok "L6 second report while one is open -> 409 PT409 loss_report_open" "$([[ $c == 409 && $(eb) == PT409\|loss_report_open\|* ]] && echo 1)" "HTTP $c $(eb)"
Q -c "select kodhane_loss.loss_report_reject($RID, 'kayip_bulunamadi', 'http test')" >/dev/null
EXP=$(Q -c "select to_char((created_at + interval '24 hours') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') from kodhane_loss.loss_report where id = $RID")
c=$(api $U2 $CR '{"p_lost_items":["diger"]}'); ok "L7 after a rejection, same day -> 429 PT429 loss_report_daily_limit, details = created_at + 24 h (UTC ISO Z)" "$([[ $c == 429 && $(eb) == "PT429|loss_report_daily_limit|$EXP" ]] && echo 1)" "HTTP $c $(eb) (expected $EXP)"
h=$(curl -s -D - -o "$BODY" -H "Authorization: Bearer $(jwt $U2)" -H 'Content-Type: application/json' -X POST "$BASE/$CR" -d '{"p_lost_items":["diger"]}' | tr -d '\r')
ok "L7b same 429 again: no Retry-After header (the retry time is only in details, UTC ISO Z)" \
  "$([[ $(head -n1 <<< "$h") == *' 429'* ]] && ! grep -qi '^retry-after:' <<< "$h" && [[ $(eb | cut -d'|' -f3) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo 1)" "$(head -n1 <<< "$h"), headers: $(grep -ci '^retry-after:' <<< "$h") Retry-After, details $(eb | cut -d'|' -f3)"
# 5 reports in 30 days, none in the last 24 h: move the first back 6 days, add 4 rejected ones 2 ... 5 days ago
Q -c "update kodhane_loss.loss_report set created_at = now() - interval '6 days', status_changed_at = now() - interval '6 days' where id = $RID" >/dev/null
for k in 2 3 4 5; do
  Q -c "select t.login('$U2')" -c "select public.kodhane_loss_report_create('{diger}', null)" >/dev/null
  n=$(Q -c "select max(id) from kodhane_loss.loss_report where user_id = '$U2'")
  Q -c "select kodhane_loss.loss_report_reject($n, 'diger')" -c "update kodhane_loss.loss_report set created_at = now() - interval '$k days' where id = $n" >/dev/null
done
EXP=$(Q -c "select to_char((min(created_at) + interval '30 days') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') from kodhane_loss.loss_report where user_id = '$U2'")
c=$(api $U2 $CR '{"p_lost_items":["diger"]}'); ok "L8 5 reports in 30 days -> 429 PT429 loss_report_monthly_limit, details = oldest + 30 days" "$([[ $c == 429 && $(eb) == "PT429|loss_report_monthly_limit|$EXP" ]] && echo 1)" "HTTP $c $(eb) (expected $EXP)"
c=$(api $U2 rpc/kodhane_loss_report_status '{"p_limit":10}'); b=$(cat "$BODY")
ok "L9 status RPC -> 200, 5 own rows, exactly the 10 columns, rejected + reason code, review_reason and applied_revision null" \
  "$([[ $c == 200 ]] && python3 -c '
import json,sys; j=json.loads(sys.argv[1]); rid=int(sys.argv[2])
cols={"id","created_at","lost_items","lost_since","status","status_changed_at","reason","applied_at","review_reason","applied_revision"}
r=[x for x in j if x["id"]==rid]
print(1 if len(j)==5 and all(set(x)==cols for x in j) and all(x["status"]=="rejected" and x["review_reason"] is None and x["applied_revision"] is None for x in j) and r and r[0]["reason"]=="kayip_bulunamadi" and r[0]["lost_items"]==["agac","borsa_payi"] else 0)' "$b" "$RID")" "HTTP $c $(head -c 200 <<< "$b")"
# restore + old tab (U1): progress before 'h_before', then a loss; report, approve, apply; the old tab writes its revision
HAS=$(Q -c "select count(*) from public.kodhane_saves where user_id = '$U1'")
[[ $HAS == 1 ]] || Q -c "select t.login('$U1')" -c "select t.ki(t.save0())" >/dev/null 2>&1
Q -c "select t.login('$U1')" -c "select t.kw('{\"version\": 5, \"saveVersion\": 5, \"shares\": 10, \"prestigeCount\": 10, \"cycleRounds\": 10, \"tree\": [\"kod_1\", \"kod_2\"]}'::jsonb)" >/dev/null
Q -c "select t.tmark('h_before')" >/dev/null
Q -c "select t.login('$U1')" -c "select t.kw('{\"shares\": 3, \"tree\": [\"kod_1\"]}'::jsonb)" >/dev/null
REV=$(Q -c "select revision from public.kodhane_saves where user_id = '$U1'"); DATA=$(Q -c "select data::text from public.kodhane_saves where user_id = '$U1'")
c=$(api $U1 $CR '{"p_lost_items":["yatirim_turu","agac"],"p_lost_since":null}'); R1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",0))' "$BODY" 2>/dev/null || echo 0)
r=$(Q -c "select kodhane_loss.loss_report_approve($R1, 'KD-TLF-2026-10-03-81', t.at('h_before')) ->> 'result'" -c "select kodhane_loss.loss_report_apply($R1, 'KD-TLF-2026-10-03-81') ->> 'result'" | tr '\n' ' ')
c2=$(api $U1 rpc/kodhane_loss_report_status '{}'); st=$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(j[0]["status"], j[0]["applied_at"] is not None, j[0]["review_reason"], j[0]["applied_revision"])' "$BODY")
ok "L10 lost_since null (Bilmiyorum) report -> approve + apply -> status RPC: applied, applied_at set, applied_revision = revision written by the restore" "$([[ $c == 200 && $r == 'approved applied ' && $c2 == 200 && $st == "applied True None $((REV+1))" ]] && echo 1)" "create $c, ops: $r, status $c2: $st"
row=$(python3 -c 'import json,sys; print(json.dumps({"user_id":sys.argv[1],"data":json.loads(sys.argv[2]),"save_version":5,"updated_at":"2026-10-03T12:00:00Z","revision":int(sys.argv[3])+1}))' "$U1" "$DATA" "$REV")
c=$(curl -s -o "$BODY" -w '%{http_code}' -H "Authorization: Bearer $(jwt $U1)" -H 'Content-Type: application/json' -H 'Prefer: resolution=merge-duplicates,return=minimal' \
     -X POST "$BASE/kodhane_saves?on_conflict=user_id" -d "$row")
ok "L11 old tab after the restore writes revision $((REV+1)) (= server revision) -> 409 PT409 stale_revision; restored save kept" \
  "$([[ $c == 409 && $(eb) == PT409\|stale_revision\|* && $(Q -c "select data->>'shares' from public.kodhane_saves where user_id = '$U1'") == 10 ]] && echo 1)" "HTTP $c $(eb)"
# L11b: the client's exact rule (istemci notu §2): old tab's sent revision (409 details "sent revision N, ...") <= applied_revision
#       -> the 409 came from the restore (staleTab text); here N = REV + 1 = applied_revision
c2=$(api $U1 rpc/kodhane_loss_report_status '{}'); ar=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["applied_revision"])' "$BODY" 2>/dev/null)
c=$(curl -s -o "$BODY" -w '%{http_code}' -H "Authorization: Bearer $(jwt $U1)" -H 'Content-Type: application/json' -H 'Prefer: resolution=merge-duplicates,return=minimal' \
     -X POST "$BASE/kodhane_saves?on_conflict=user_id" -d "$row"); sent=$(eb | sed -nE 's/.*sent revision ([0-9]+),.*/\1/p')
ok "L11b status applied_revision $((REV+1)); old tab 409 details sent revision $((REV+1)) <= applied_revision -> restore detected exactly" \
  "$([[ $c2 == 200 && $ar == $((REV+1)) && $c == 409 && -n $sent && $sent -le $ar ]] && echo 1)" "status $c2 applied_revision $ar; HTTP $c sent $sent"
