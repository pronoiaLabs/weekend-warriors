#!/usr/bin/env bash
# Create the Snowflake Postgres instance + its ingress network policy from
# .env.postgres, and write PGHOST / PGPASSWORD back into that file.
#
# A script rather than a committed .sql on purpose: `make setup-source
# SOURCE=postgres` globs sql/sources/postgres/*.sql, and an instance CREATE
# must never ride along on that glob. The rendered SQL lands in .generated/
# (gitignored), outside the glob.
#
# Safe on an account that already has the instance: the SHOW guard skips the
# CREATE entirely, and nothing in this script emits DROP or OR REPLACE for a
# POSTGRES INSTANCE. Re-running only reconciles the ingress policy.
#
# Usage: from dlt-pipelines/
#   set -a && source ../.env.postgres && set +a
#   ./sql/sources/postgres/apply_instance.sh
#
# Or: make setup-postgres-instance CONFIRM=1
#
# RENDER_ONLY=1 renders .generated/*.sql with the current env and exits
# without connecting to Snowflake (for offline inspection/tests).
#
# Two Snowflake Postgres facts this script is built around:
#   * CREATE POSTGRES INSTANCE has no IF NOT EXISTS / OR REPLACE, and creation
#     is async (poll DESC until state = READY).
#   * The CREATE result carries the admin passwords in `access_roles` EXACTLY
#     ONCE; they cannot be read back later. Recovery if lost:
#       ALTER POSTGRES INSTANCE "<name>" RESET ACCESS FOR 'snowflake_admin';

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../../../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.postgres"
GEN="$ROOT/.generated"
mkdir -p "$GEN"

: "${PG_INSTANCE_NAME:?PG_INSTANCE_NAME is required (see .env.postgres.example)}"
: "${PG_COMPUTE_FAMILY:?PG_COMPUTE_FAMILY is required (see .env.postgres.example)}"
: "${PG_STORAGE_GB:?PG_STORAGE_GB is required (see .env.postgres.example)}"
: "${PG_VERSION:?PG_VERSION is required (see .env.postgres.example)}"
: "${PG_INGRESS_POLICY:?PG_INGRESS_POLICY is required (see .env.postgres.example)}"
: "${PG_CLIENT_CIDRS:?PG_CLIENT_CIDRS is required (comma-separated laptop/office CIDRs)}"

snow_sql() { snow sql ${SNOW_CONN:+-c "$SNOW_CONN"} "$@"; }

# The instance name is a quoted identifier (the owner's is "Weekend Warrior
# App", spaces and case preserved). Double quotes in SQL identifiers, single
# quotes in string literals (SHOW ... LIKE).
name_ident="\"${PG_INSTANCE_NAME//\"/\"\"}\""
name_lit="${PG_INSTANCE_NAME//\'/\'\'}"

# Comma-separated CIDRs -> quoted SQL list: 'a/32', 'b/24'
sql_cidr_list() {
  local out="" item
  IFS=',' read -ra items <<< "$1"
  for item in "${items[@]}"; do
    item="$(echo "$item" | tr -d '[:space:]')"
    [ -z "$item" ] && continue
    out="${out:+$out, }'${item//\'/\'\'}'"
  done
  [ -n "$out" ] || { echo "no usable CIDRs in: $1" >&2; return 1; }
  printf '%s' "$out"
}
client_cidrs_sql="$(sql_cidr_list "$PG_CLIENT_CIDRS")"

# Update KEY= in .env.postgres: fill when blank/absent, leave a non-empty value
# alone (returns 1 so the caller can warn). Same write-back idea as
# sql/postgres/apply.sh uses for APP_COPY_WRITER_PASSWORD.
update_env() {
  local key="$1" value="$2"
  [ -f "$ENV_FILE" ] || { printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"; return 0; }
  local current
  current="$(grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
  if [ -z "$current" ] || [ "$current" = "xxxxx.region.aws.postgres.snowflake.app" ]; then
    if grep -qE "^${key}=" "$ENV_FILE"; then
      # portable in-place edit (BSD/GNU sed differ); python keeps it exact
      KEY="$key" VALUE="$value" ENVF="$ENV_FILE" python3 - <<'PY'
import os, re
key, value, path = os.environ["KEY"], os.environ["VALUE"], os.environ["ENVF"]
text = open(path).read()
text = re.sub(rf"^{re.escape(key)}=.*$", f"{key}={value}", text, count=1, flags=re.M)
open(path, "w").write(text)
PY
    else
      printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
    return 0
  fi
  [ "$current" = "$value" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Render .generated/00_create_instance.sql (always, so RENDER_ONLY can inspect)
# ---------------------------------------------------------------------------
create_sql="$GEN/00_create_instance.sql"
cat > "$create_sql" <<EOF
USE ROLE SYSADMIN;
-- No IF NOT EXISTS exists for this statement; apply_instance.sh guards with
-- SHOW POSTGRES INSTANCES before applying this file. POSTGRES_OR_SNOWFLAKE
-- keeps password login working and additionally allows short-lived Snowflake
-- tokens (matches the owner's instance).
CREATE POSTGRES INSTANCE $name_ident
  COMPUTE_FAMILY = '${PG_COMPUTE_FAMILY//\'/\'\'}'
  STORAGE_SIZE_GB = ${PG_STORAGE_GB}
  POSTGRES_VERSION = ${PG_VERSION}
  AUTHENTICATION_AUTHORITY = POSTGRES_OR_SNOWFLAKE
  COMMENT = 'weekend-warriors app copy target (created by sql/sources/postgres/apply_instance.sh)';
EOF

if [ "${RENDER_ONLY:-}" = "1" ]; then
  # Fresh-account shape of the policy SQL, for inspection only.
  policy_sql="$GEN/01_instance_policy.sql"
  cat > "$policy_sql" <<EOF
USE ROLE ACCOUNTADMIN;
CREATE NETWORK RULE IF NOT EXISTS DLT_DB.OPS.POSTGRES_INGRESS_CLIENTS
  TYPE = IPV4
  MODE = POSTGRES_INGRESS
  VALUE_LIST = ($client_cidrs_sql)
  COMMENT = 'Client CIDRs (laptop/office) allowed to reach :5432 on the Postgres instance.';
ALTER NETWORK RULE DLT_DB.OPS.POSTGRES_INGRESS_CLIENTS
  SET VALUE_LIST = ($client_cidrs_sql);
CREATE NETWORK POLICY ${PG_INGRESS_POLICY}
  ALLOWED_NETWORK_RULE_LIST = ('DLT_DB.OPS.POSTGRES_INGRESS_CLIENTS');
ALTER POSTGRES INSTANCE $name_ident SET NETWORK_POLICY = '${PG_INGRESS_POLICY}';
EOF
  echo "RENDER_ONLY: wrote $create_sql and $policy_sql (nothing applied)."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Existence guard: never touch an instance that already exists
# ---------------------------------------------------------------------------
echo "== checking for existing instance '$PG_INSTANCE_NAME' =="
existing="$(snow_sql --format json -q "SHOW POSTGRES INSTANCES LIKE '$name_lit'" \
  | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')"

parse_fail=0
if [ "$existing" != "0" ]; then
  echo "Instance '$PG_INSTANCE_NAME' exists; skipping CREATE (this script never drops or recreates)."
else
  echo "== applying $create_sql (creation is async; billing starts when it is READY) =="
  # The password parser lives in a gitignored file rather than a heredoc
  # inside $(...): macOS's /bin/bash 3.2 cannot parse that construct.
  parse_py="$GEN/parse_access_roles.py"
  cat > "$parse_py" <<'PY'
import json
import re
import sys

raw = sys.stdin.read()


def walk(node, found):
    if isinstance(node, dict):
        for k, v in node.items():
            if "access_roles" in str(k).lower() and isinstance(v, str):
                found.append(v)
            walk(v, found)
    elif isinstance(node, list):
        for item in node:
            walk(item, found)


blobs = []
try:
    walk(json.loads(raw), blobs)
except Exception:
    pass
blobs.append(raw)  # fall back to scanning the raw output

for blob in blobs:
    # snowflake_admin's password, whichever way the result spells the pairing
    m = re.search(
        r"snowflake_admin[^{}\[\]]*?password\"?\s*[:=]\s*\"?([^\s\",}]+)", blob, re.I
    ) or re.search(
        r"\"?password\"?\s*[:=]\s*\"?([^\s\",}]+)[^{}\[\]]*?snowflake_admin", blob, re.I
    )
    if m:
        print(m.group(1))
        break
PY
  # Capture the result in a shell variable, never on disk: the one-time
  # access_roles passwords ride in it.
  out="$(snow_sql --format json -f "$create_sql")"
  admin_pass="$(printf '%s' "$out" | python3 "$parse_py")"
  if [ -n "$admin_pass" ]; then
    if update_env PGPASSWORD "$admin_pass"; then
      echo "Wrote PGPASSWORD (snowflake_admin) into $ENV_FILE"
    else
      # A stale non-empty PGPASSWORD was already there; do not lose the only
      # copy of the new one. .generated/ is gitignored.
      printf '%s\n' "$admin_pass" > "$GEN/instance_admin_password.txt"
      chmod 600 "$GEN/instance_admin_password.txt"
      echo "WARNING: $ENV_FILE already had a PGPASSWORD; the NEW snowflake_admin"
      echo "password was saved to $GEN/instance_admin_password.txt -- move it into"
      echo ".env.postgres and delete that file."
    fi
  else
    parse_fail=1
    echo "WARNING: could not find the snowflake_admin password in the CREATE output."
    echo "It is shown exactly once and was NOT saved. Regenerate it with:"
    echo "  ALTER POSTGRES INSTANCE $name_ident RESET ACCESS FOR 'snowflake_admin';"
    echo "then put the new value in $ENV_FILE as PGPASSWORD."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Poll until READY, then record the hostname
# ---------------------------------------------------------------------------
echo "== waiting for state = READY (30s polls, 20 min timeout) =="
state=""
host=""
for _ in $(seq 1 40); do
  desc="$(snow_sql --format json -q "DESC POSTGRES INSTANCE $name_ident")"
  state="$(printf '%s' "$desc" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
props = { str(r.get("property", r.get("name", ""))).lower(): r.get("value") for r in rows }
print(props.get("state") or "")')"
  host="$(printf '%s' "$desc" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
props = { str(r.get("property", r.get("name", ""))).lower(): r.get("value") for r in rows }
print(props.get("host") or "")')"
  echo "  state: ${state:-unknown}"
  [ "$state" = "READY" ] && break
  sleep 30
done
if [ "$state" != "READY" ]; then
  echo "Instance did not reach READY in 20 minutes. Check: DESC POSTGRES INSTANCE $name_ident" >&2
  exit 1
fi

if [ -n "$host" ]; then
  if update_env PGHOST "$host"; then
    echo "PGHOST=$host recorded in $ENV_FILE"
  else
    echo "WARNING: $ENV_FILE has a different non-placeholder PGHOST; expected $host -- fix it by hand."
  fi
fi

# ---------------------------------------------------------------------------
# 3. Ingress policy: create if missing, extend if present, never replace.
#    An existing policy (e.g. the Snowsight-created one) keeps every rule it
#    has; we only ADD our clients rule when it is absent. SET would drop the
#    others -- same trap 04_ingress_spcs.sql documented.
# ---------------------------------------------------------------------------
policy_sql="$GEN/01_instance_policy.sql"
{
  echo "USE ROLE ACCOUNTADMIN;"
  echo "CREATE NETWORK RULE IF NOT EXISTS DLT_DB.OPS.POSTGRES_INGRESS_CLIENTS"
  echo "  TYPE = IPV4"
  echo "  MODE = POSTGRES_INGRESS"
  echo "  VALUE_LIST = ($client_cidrs_sql)"
  echo "  COMMENT = 'Client CIDRs (laptop/office) allowed to reach :5432 on the Postgres instance.';"
  echo "ALTER NETWORK RULE DLT_DB.OPS.POSTGRES_INGRESS_CLIENTS"
  echo "  SET VALUE_LIST = ($client_cidrs_sql);"
} > "$policy_sql"

policy_exists="$(snow_sql --format json -q "SHOW NETWORK POLICIES LIKE '${PG_INGRESS_POLICY//\'/\'\'}'" \
  | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')"
if [ "$policy_exists" = "0" ]; then
  {
    echo "CREATE NETWORK POLICY ${PG_INGRESS_POLICY}"
    echo "  ALLOWED_NETWORK_RULE_LIST = ('DLT_DB.OPS.POSTGRES_INGRESS_CLIENTS');"
  } >> "$policy_sql"
else
  has_rule="$(snow_sql --format json -q "DESCRIBE NETWORK POLICY ${PG_INGRESS_POLICY}" \
    | python3 -c 'import sys, json
rows = json.load(sys.stdin)
text = json.dumps(rows).upper()
print(1 if "DLT_DB.OPS.POSTGRES_INGRESS_CLIENTS" in text else 0)')"
  if [ "$has_rule" = "0" ]; then
    {
      echo "-- policy pre-exists: ADD our rule, keep everything already on it"
      echo "ALTER NETWORK POLICY ${PG_INGRESS_POLICY}"
      echo "  ADD ALLOWED_NETWORK_RULE_LIST = ('DLT_DB.OPS.POSTGRES_INGRESS_CLIENTS');"
    } >> "$policy_sql"
  fi
fi
echo "ALTER POSTGRES INSTANCE $name_ident SET NETWORK_POLICY = '${PG_INGRESS_POLICY}';" >> "$policy_sql"

echo "== applying $policy_sql =="
snow_sql -f "$policy_sql"

echo ""
echo "Instance ready. Next (see MAKE-COMMANDS-POSTGRES.md / SETUP.md):"
echo "  make setup-postgres CONFIRM=1                 # database app, schemas, roles (psql)"
echo "  make setup-source SOURCE=postgres CONFIRM=1   # secret placeholder + EAI/ingress from PGHOST"
echo "  make setup-postgres-secret CONFIRM=1"
echo "  make setup-postgres-api-password CONFIRM=1"
echo "  make setup-postgres-observability CONFIRM=1"

exit $parse_fail
