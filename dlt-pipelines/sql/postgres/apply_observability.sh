#!/usr/bin/env bash
# Apply sql/postgres/05*.sql + 06 against the existing `app` database.
#
# Required env (normally sourced from the repo-root .env.postgres):
#   PGHOST PGPORT PGUSER PGPASSWORD APP_COPY_WRITER_PASSWORD
#
# Usage: from dlt-pipelines/
#   set -a && source ../.env.postgres && set +a
#   ./sql/postgres/apply_observability.sh
#
# Or: make setup-postgres-observability CONFIRM=1

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${APP_COPY_WRITER_PASSWORD:?APP_COPY_WRITER_PASSWORD is required}"

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

echo "== applying $ROOT/05_observability.sql =="
psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/05_observability.sql"

echo "== applying $ROOT/05b_observability_default_privileges.sql as app_copy_writer =="
PGUSER=app_copy_writer PGPASSWORD="$APP_COPY_WRITER_PASSWORD" \
  psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/05b_observability_default_privileges.sql"

echo "== applying $ROOT/06_grant_observability_select.sql as app_copy_writer =="
PGUSER=app_copy_writer PGPASSWORD="$APP_COPY_WRITER_PASSWORD" \
  psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/06_grant_observability_select.sql"

echo "Postgres app.observability / observability_watermark ready."
echo "Next: make run-postgres NAME=obs_to_postgres"
