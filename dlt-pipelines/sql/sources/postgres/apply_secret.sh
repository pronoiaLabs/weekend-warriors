#!/usr/bin/env bash
# Render and apply ALTER SECRET DLT_DB.OPS.POSTGRES_APP_COPY from
# APP_COPY_WRITER_PASSWORD. The rendered SQL is gitignored.
#
# Usage: from dlt-pipelines/
#   set -a && source ../.env.postgres && set +a
#   ./sql/sources/postgres/apply_secret.sh
#
# Or: make setup-postgres-secret

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GEN="$ROOT/.generated"
mkdir -p "$GEN"

: "${APP_COPY_WRITER_PASSWORD:?APP_COPY_WRITER_PASSWORD is required}"

# Escape single quotes for a Snowflake STRING literal.
escaped="${APP_COPY_WRITER_PASSWORD//\'/\'\'}"
sql="$GEN/03_set_secret.sql"
cat > "$sql" <<EOF
USE ROLE SYSADMIN;
ALTER SECRET DLT_DB.OPS.POSTGRES_APP_COPY SET SECRET_STRING = '$escaped';
EOF

echo "== applying $sql =="
snow sql ${SNOW_CONN:+-c "$SNOW_CONN"} -f "$sql"
echo "POSTGRES_APP_COPY secret set. Value cannot be read back; a copy run is the test."
