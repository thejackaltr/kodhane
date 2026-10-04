# Shared by ops/kodhane_deletion_log_{install,export,reapply}.sh (sourced, not run). Target selection as in
# ops/kodhane_v44b_install.sh:
#   KODHANE_TARGET=local  KODHANE_CT=<docker container> KODHANE_DB=<database>   (docker exec psql -U supabase_admin)
#   KODHANE_TARGET=live   PORTAINER_API_TOKEN exported (never printed); KODHANE_PEXEC (default
#                         /workspace/kodhane-cloud/pexec.sh), KODHANE_PENV (penv_md5.py): Portainer exec on puffin,
#                         psql -U supabase_admin -d postgres in infrastructure-supabase-eqbmlp-db-1
dl_ts() { date '+%Y-%m-%d %H:%M:%S TSİ'; }
dl_die() { echo "STOP: $*"; exit 1; }
DL_PREFIX='\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on
\pset footer off'
dl_target_init() {
  DL_TARGET="${KODHANE_TARGET:-}"
  DL_PEXEC="${KODHANE_PEXEC:-/workspace/kodhane-cloud/pexec.sh}"; DL_PENV="${KODHANE_PENV:-/workspace/kodhane-cloud/penv_md5.py}"
  case "$DL_TARGET" in
    local) [[ -n "${KODHANE_CT:-}" && -n "${KODHANE_DB:-}" ]] || dl_die "KODHANE_TARGET=local needs KODHANE_CT and KODHANE_DB" ;;
    live)  [[ -n "${PORTAINER_API_TOKEN:-}" ]] || dl_die "PORTAINER_API_TOKEN is not exported"
           for f in "$DL_PEXEC" "$DL_PENV"; do [[ -r "$f" ]] || dl_die "missing $f"; done ;;
    *) dl_die "KODHANE_TARGET must be local or live" ;;
  esac
}
# dl_run_sql <sql file> <output file>: runs the file on the target, output (stdout + stderr, no CR) to <output file>;
# returns psql's exit code. Live: the file goes through an environment variable (pexec), so it must stay < 120000 bytes.
dl_run_sql() {
  local f=$1 o=$2 rc
  if [[ "$DL_TARGET" == local ]]; then
    docker exec -i "$KODHANE_CT" psql -X -U supabase_admin -d "$KODHANE_DB" -f - < "$f" > "$o" 2>&1; rc=$?
  else
    (( $(stat -c %s "$f") < 120000 )) || { echo "generated SQL too large for pexec ($(stat -c %s "$f") bytes)" > "$o"; return 98; }
    python3 "$DL_PENV" "$f" > "$o.penv" 2>&1
    grep -q ' MATCH' "$o.penv" || { cat "$o.penv" > "$o"; echo "penv_md5: file did not arrive intact" >> "$o"; return 97; }
    bash "$DL_PEXEC" "$f" 2>&1 | tr -d '\r' > "$o"
    rc=$(grep -oE '__EXIT=[0-9]+' "$o" | tail -n1 | cut -d= -f2); rc=${rc:-99}
  fi
  return "$rc"
}
