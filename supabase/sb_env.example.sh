#!/usr/bin/env bash
# Template for the LOCAL, uncommitted sb_env.sh that the live (KODHANE_TARGET=live) ops scripts expect to be sourced.
# Copy outside the repo (or to supabase/sb_env.sh, which .gitignore excludes), fill in, then: source sb_env.sh
# Never commit real values. Scripts never print them; an empty variable stops the live script (no defaults).

# Portainer API token (never printed).
export PORTAINER_API_TOKEN='<portainer-api-token>'

# Portainer Docker API base URL for the endpoint that runs the database, no trailing slash:
#   https://<portainer-host>/api/endpoints/<endpoint-id>/docker
export KODHANE_PORTAINER_URL='<portainer-docker-api-url>'

# Name of the Postgres container of the Supabase stack (psql -U supabase_admin -d postgres runs in it).
export KODHANE_DB_CONTAINER='<db-container-name>'

# Dokploy compose name of the same stack (docs only: scheduled retention task, service db).
export KODHANE_DB_COMPOSE='<db-compose-name>'
