#!/usr/bin/env bash
# Render and apply the ALTER SECRET statements that no committed DDL can carry:
# the real API keys and the Slack webhook path. Values come from the repo-root
# .env.snowflake (copy .env.snowflake.example); the rendered SQL is gitignored.
#
# Empty vars are SKIPPED (listed by name), so a partial file is fine and
# re-running never blanks a secret that was already set. Re-running with the
# same values is a same-value ALTER: harmless.
#
# The placeholder secrets themselves are created by:
#   make setup-source SOURCE=<nfl|ncaaf|firecrawl> CONFIRM=1   (API keys)
#   make setup-ops CONFIRM=1                                        (Slack webhook)
# This script only sets their values. Values cannot be read back from
# Snowflake; a successful pipeline run (make run-spcs NAME=nfl_reference) or a
# NOTIFICATION_HISTORY() row is the test.
#
# Usage: from dlt-pipelines/
#   set -a && source ../.env.snowflake && set +a
#   ./sql/secrets/apply_secrets.sh
#
# Or: make setup-secrets CONFIRM=1
#
# RENDER_ONLY=1 renders .generated/set_secrets.sql and exits without applying.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GEN="$ROOT/.generated"
mkdir -p "$GEN"

# VAR -> SECRET, one line per mapping. Extend when a new source's 03_secrets.sql
# adds a placeholder secret.
MAPPINGS=(
  "NFL_API_KEY:DLT_DB.OPS.NFL_API_KEY"
  "NCAAF_API_KEY:DLT_DB.OPS.NCAAF_API_KEY"
  "FIRECRAWL_API_KEY:DLT_DB.OPS.FIRECRAWL_API_KEY"
  "SLACK_WEBHOOK_SECRET:DLT_DB.OPS.SLACK_ALERTS_WEBHOOK"
)

sql="$GEN/set_secrets.sql"
{
  echo "-- Rendered by apply_secrets.sh from .env.snowflake. Never commit."
  echo "USE ROLE SYSADMIN;"
} > "$sql"

set_count=0
skipped=()
for mapping in "${MAPPINGS[@]}"; do
  var="${mapping%%:*}"
  secret="${mapping#*:}"
  value="${!var:-}"
  if [ -z "$value" ]; then
    skipped+=("$var")
    continue
  fi
  escaped="${value//\'/\'\'}"
  printf "ALTER SECRET %s SET SECRET_STRING = '%s';\n" "$secret" "$escaped" >> "$sql"
  set_count=$((set_count + 1))
done

if [ ${#skipped[@]} -gt 0 ]; then
  echo "Skipped (empty in env): ${skipped[*]}"
fi
if [ "$set_count" = "0" ]; then
  echo "Nothing to set: every mapped var is empty. Fill .env.snowflake first."
  exit 0
fi

if [ "${RENDER_ONLY:-}" = "1" ]; then
  echo "RENDER_ONLY: wrote $sql with $set_count ALTER(s) (nothing applied)."
  exit 0
fi

echo "== applying $sql ($set_count secret(s)) =="
snow sql ${SNOW_CONN:+-c "$SNOW_CONN"} -f "$sql"
echo "Done. Values cannot be read back; a pipeline run is the test."
