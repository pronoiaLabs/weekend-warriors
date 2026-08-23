#!/usr/bin/env bash
# Set (or rotate) the app_api login password. Does not recreate the database.
#
# Required env (normally sourced from the repo-root .env.postgres):
#   PGHOST PGPORT PGUSER PGPASSWORD
# APP_API_PASSWORD is generated and appended to .env.postgres if missing.
#
# Usage: from dlt-pipelines/
#   set -a && source ../.env.postgres && set +a
#   ./sql/postgres/apply_api_password.sh
#
# Or: make setup-postgres-api-password CONFIRM=1

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.postgres"
GEN="$ROOT/.generated"
mkdir -p "$GEN"

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"

if [ -z "${APP_API_PASSWORD:-}" ]; then
  APP_API_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
  if [ -f "$ENV_FILE" ]; then
    printf '\nAPP_API_PASSWORD=%s\n' "$APP_API_PASSWORD" >> "$ENV_FILE"
    echo "Generated APP_API_PASSWORD and appended it to $ENV_FILE"
  else
    echo "Generated APP_API_PASSWORD (no $ENV_FILE to append to)."
    echo "Write it down and put it in .env.postgres."
  fi
fi

export PGSSLMODE="${PGSSLMODE:-require}"

if [ -x /opt/homebrew/opt/libpq/bin/psql ]; then
  PATH="/opt/homebrew/opt/libpq/bin:$PATH"
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required. brew install libpq  (keg-only: /opt/homebrew/opt/libpq/bin)" >&2
  exit 2
fi

exists="$(psql -d postgres -v ON_ERROR_STOP=1 -Atc \
  "SELECT 1 FROM pg_database WHERE datname = 'app'")"
if [ "$exists" != "1" ]; then
  echo "database app does not exist. make setup-postgres CONFIRM=1 first." >&2
  exit 2
fi

pass_sql="$GEN/07_set_api_password.sql"
printf "ALTER ROLE app_api PASSWORD \$pw\$%s\$pw\$;\n" \
  "$APP_API_PASSWORD" > "$pass_sql"
echo "== applying $pass_sql =="
psql -d app -v ON_ERROR_STOP=1 -f "$pass_sql"

echo "== proving app_api can SELECT app_copy.app_copy_watermark =="
PGUSER=app_api PGPASSWORD="$APP_API_PASSWORD" PGDATABASE=app \
  psql -d app -v ON_ERROR_STOP=1 -Atc \
  "SELECT count(*) FROM app_copy.app_copy_watermark"

echo "app_api password set. analytics-dashboard and ops-dashboard make serve/dev source APP_API_PASSWORD."
