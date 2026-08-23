#!/usr/bin/env bash
# Apply sql/postgres/*.sql against the Snowflake Postgres instance.
#
# Required env (normally sourced from the repo-root .env.postgres):
#   PGHOST PGPORT PGUSER PGPASSWORD
# APP_COPY_WRITER_PASSWORD is generated and appended to .env.postgres if missing.
#
# Usage: from dlt-pipelines/
#   set -a && source ../.env.postgres && set +a
#   ./sql/postgres/apply.sh
#
# Or: make setup-postgres CONFIRM=1

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

if [ -z "${APP_COPY_WRITER_PASSWORD:-}" ]; then
  APP_COPY_WRITER_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
  if [ -f "$ENV_FILE" ]; then
    printf '\nAPP_COPY_WRITER_PASSWORD=%s\n' "$APP_COPY_WRITER_PASSWORD" >> "$ENV_FILE"
    echo "Generated APP_COPY_WRITER_PASSWORD and appended it to $ENV_FILE"
  else
    echo "Generated APP_COPY_WRITER_PASSWORD (no $ENV_FILE to append to)."
    echo "Write it down and put it in .env.postgres before setup-postgres-secret."
  fi
fi

export PGSSLMODE="${PGSSLMODE:-require}"
export PGDATABASE="${PGDATABASE:-postgres}"

# Homebrew libpq is keg-only and is not on PATH unless the user exported it.
if [ -x /opt/homebrew/opt/libpq/bin/psql ]; then
  PATH="/opt/homebrew/opt/libpq/bin:$PATH"
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required. brew install libpq  (keg-only: /opt/homebrew/opt/libpq/bin)" >&2
  exit 2
fi

exists="$(psql -d postgres -v ON_ERROR_STOP=1 -Atc \
  "SELECT 1 FROM pg_database WHERE datname = 'app'")"
if [ "$exists" = "1" ]; then
  echo "== app database already exists; skipping 01_create_database.sql =="
else
  echo "== applying $ROOT/01_create_database.sql =="
  psql -d postgres -v ON_ERROR_STOP=1 -f "$ROOT/01_create_database.sql"
fi

echo "== applying $ROOT/02_app_copy.sql =="
psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/02_app_copy.sql"

# Password cannot live in git. Render from env into a gitignored file, then apply.
pass_sql="$GEN/03_set_writer_password.sql"
printf "ALTER ROLE app_copy_writer PASSWORD \$pw\$%s\$pw\$;\n" \
  "$APP_COPY_WRITER_PASSWORD" > "$pass_sql"
echo "== applying $pass_sql =="
psql -d app -v ON_ERROR_STOP=1 -f "$pass_sql"

# Default privileges must be recorded as app_copy_writer. SET ROLE from the
# admin session is denied on this instance.
echo "== applying $ROOT/02b_default_privileges.sql as app_copy_writer =="
PGUSER=app_copy_writer PGPASSWORD="$APP_COPY_WRITER_PASSWORD" \
  psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/02b_default_privileges.sql"

# Writer owns the marts; admin cannot GRANT on them.
echo "== applying $ROOT/04_grant_admin_select.sql as app_copy_writer =="
PGUSER=app_copy_writer PGPASSWORD="$APP_COPY_WRITER_PASSWORD" \
  psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/04_grant_admin_select.sql"

# Same instance, same writer. Schema only; copy tables arrive on first
# obs_to_postgres run.
echo "== applying $ROOT/05_observability.sql =="
psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/05_observability.sql"

echo "== applying $ROOT/05b_observability_default_privileges.sql as app_copy_writer =="
PGUSER=app_copy_writer PGPASSWORD="$APP_COPY_WRITER_PASSWORD" \
  psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/05b_observability_default_privileges.sql"

echo "== applying $ROOT/06_grant_observability_select.sql as app_copy_writer =="
PGUSER=app_copy_writer PGPASSWORD="$APP_COPY_WRITER_PASSWORD" \
  psql -d app -v ON_ERROR_STOP=1 -f "$ROOT/06_grant_observability_select.sql"

echo "Postgres app / app_copy / observability / app_copy_writer ready."
echo "Next: make setup-source SOURCE=postgres CONFIRM=1"
echo "      make setup-postgres-secret CONFIRM=1"
echo "      snow sql -f sql/sources/nfl/07_app_copy_grants.sql"
