#!/usr/bin/env bash
# Render + apply the two account-specific Postgres network files from env:
#
#   .generated/02_external_access.sql  egress: SPCS -> $PGHOST:5432 (rule + EAI)
#   .generated/04_ingress_spcs.sql     ingress: Snowflake egress CIDRs onto the
#                                      instance policy, so SPCS jobs can connect
#
# These used to be committed files carrying the owner's hostname and pinned
# CIDRs; now the host comes from .env.postgres PGHOST and the CIDRs are
# discovered live from SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES() (they expire --
# re-run this target when Snowflake rotates them; PG_SNOWFLAKE_EGRESS_CIDRS in
# the env pins them instead if you need to).
#
# The EAI only lets the container *try* to open :5432; the instance-level
# POSTGRES_INGRESS policy still has to accept the source IPs, which is what
# the 04 render does. Laptop-only ingress is why the first copy Task timed out
# on :5432 (2026-08-23). Do not add 0.0.0.0/0 to either side.
#
# Usage: from dlt-pipelines/
#   set -a && source ../.env.postgres && set +a
#   ./sql/sources/postgres/apply_network.sh
#
# Or: make setup-postgres-network CONFIRM=1   (also run by
#     make setup-source SOURCE=postgres CONFIRM=1 after the *.sql glob)
#
# RENDER_ONLY=1 renders with the current env (PG_SNOWFLAKE_EGRESS_CIDRS
# required, no discovery) and exits without connecting.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GEN="$ROOT/.generated"
mkdir -p "$GEN"

: "${PGHOST:?PGHOST is required (set by make setup-postgres-instance, or copy it from DESC POSTGRES INSTANCE)}"
# Defaults to the policy name the old committed 04_ingress_spcs.sql hardcoded,
# so a .env.postgres that predates the PG_* vars keeps working unchanged.
PG_INGRESS_POLICY="${PG_INGRESS_POLICY:-POSTGRES_INGRESS_POLICY_WEEKEND_WARRIOR_APP}"

snow_sql() { snow sql ${SNOW_CONN:+-c "$SNOW_CONN"} "$@"; }

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

# ---------------------------------------------------------------------------
# 02: host-only egress EAI. OR REPLACE on purpose -- a host change (new
# instance) must take on re-run, and USAGE is re-granted right below.
# ---------------------------------------------------------------------------
egress_sql="$GEN/02_external_access.sql"
cat > "$egress_sql" <<EOF
-- Rendered by apply_network.sh from .env.postgres (PGHOST). Do not edit.
-- Host only. Do not add 0.0.0.0/0. Laptop access is the instance-level
-- POSTGRES_INGRESS network policy, not this EAI.
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE DLT_DB.OPS.POSTGRES_APP_EGRESS
    MODE     = EGRESS
    TYPE     = HOST_PORT
    VALUE_LIST = (
        '${PGHOST//\'/\'\'}:5432'
    )
    COMMENT  = 'Egress from SPCS to the Snowflake Postgres instance.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION POSTGRES_APP_EAI
    ALLOWED_NETWORK_RULES = (DLT_DB.OPS.POSTGRES_APP_EGRESS)
    ENABLED = TRUE
    COMMENT = 'External access for dlt jobs writing app.app_copy.';

GRANT USAGE ON INTEGRATION POSTGRES_APP_EAI TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON INTEGRATION POSTGRES_APP_EAI TO ROLE DLT_LOADER_ROLE;
EOF

# ---------------------------------------------------------------------------
# 04: Snowflake egress CIDRs -> POSTGRES_INGRESS rule on the instance policy
# ---------------------------------------------------------------------------
if [ -n "${PG_SNOWFLAKE_EGRESS_CIDRS:-}" ]; then
  egress_cidrs_sql="$(sql_cidr_list "$PG_SNOWFLAKE_EGRESS_CIDRS")"
  echo "Using pinned PG_SNOWFLAKE_EGRESS_CIDRS."
elif [ "${RENDER_ONLY:-}" = "1" ]; then
  echo "RENDER_ONLY needs PG_SNOWFLAKE_EGRESS_CIDRS set (no live discovery)." >&2
  exit 2
else
  # Flat JSON array of {ipv4_prefix, effective, expires}, already scoped to
  # this account's region (verified 2026-08-28 against us-east-2).
  echo "== discovering Snowflake egress CIDRs (SYSTEM\$GET_SNOWFLAKE_EGRESS_IP_RANGES) =="
  discovered="$(snow_sql --format json -q "SELECT SYSTEM\$GET_SNOWFLAKE_EGRESS_IP_RANGES() AS RANGES" \
    | python3 -c '
import json, sys
rows = json.load(sys.stdin)
ranges = json.loads(rows[0]["RANGES"])
prefixes = sorted({r["ipv4_prefix"] for r in ranges if r.get("ipv4_prefix")})
if not prefixes:
    raise SystemExit("no ipv4_prefix entries in SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES()")
print(",".join(prefixes))')"
  egress_cidrs_sql="$(sql_cidr_list "$discovered")"
  echo "  $discovered"
fi

ingress_sql="$GEN/04_ingress_spcs.sql"
cat > "$ingress_sql" <<EOF
-- Rendered by apply_network.sh. Do not edit.
-- CIDRs from SYSTEM\$GET_SNOWFLAKE_EGRESS_IP_RANGES() (or the
-- PG_SNOWFLAKE_EGRESS_CIDRS pin). They expire; re-run
-- make setup-postgres-network when Snowflake publishes new ones.
USE ROLE ACCOUNTADMIN;

CREATE NETWORK RULE IF NOT EXISTS DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS
  TYPE = IPV4
  VALUE_LIST = ($egress_cidrs_sql)
  MODE = POSTGRES_INGRESS
  COMMENT = 'Snowflake egress CIDRs so SPCS can open :5432 on the Postgres instance.';

ALTER NETWORK RULE DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS
  SET VALUE_LIST = ($egress_cidrs_sql);
EOF

if [ "${RENDER_ONLY:-}" = "1" ]; then
  # Worst-case shape for inspection: assume the policy exists without the rule.
  cat >> "$ingress_sql" <<EOF

-- Keep every rule already on the policy. ADD, do not SET (SET would drop them).
ALTER NETWORK POLICY ${PG_INGRESS_POLICY}
  ADD ALLOWED_NETWORK_RULE_LIST = ('DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS');
EOF
  echo "RENDER_ONLY: wrote $egress_sql and $ingress_sql (nothing applied)."
  exit 0
fi

# ADD only when the rule is not already on the policy: dedup by DESCRIBE, not
# by trusting ADD's duplicate semantics.
policy_exists="$(snow_sql --format json -q "SHOW NETWORK POLICIES LIKE '${PG_INGRESS_POLICY//\'/\'\'}'" \
  | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')"
if [ "$policy_exists" = "0" ]; then
  cat >> "$ingress_sql" <<EOF

CREATE NETWORK POLICY ${PG_INGRESS_POLICY}
  ALLOWED_NETWORK_RULE_LIST = ('DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS');
EOF
  echo "NOTE: policy ${PG_INGRESS_POLICY} did not exist; creating it. Attach it to the"
  echo "instance (and add your laptop CIDRs) with: make setup-postgres-instance CONFIRM=1"
else
  has_rule="$(snow_sql --format json -q "DESCRIBE NETWORK POLICY ${PG_INGRESS_POLICY}" \
    | python3 -c 'import sys, json
rows = json.load(sys.stdin)
text = json.dumps(rows).upper()
print(1 if "DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS" in text else 0)')"
  if [ "$has_rule" = "0" ]; then
    cat >> "$ingress_sql" <<EOF

-- Keep every rule already on the policy. ADD, do not SET (SET would drop them).
ALTER NETWORK POLICY ${PG_INGRESS_POLICY}
  ADD ALLOWED_NETWORK_RULE_LIST = ('DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS');
EOF
  fi
fi

echo "== applying $egress_sql =="
snow_sql -f "$egress_sql"
echo "== applying $ingress_sql =="
snow_sql -f "$ingress_sql"
echo "Postgres network ready: POSTGRES_APP_EAI -> $PGHOST:5432, ingress via ${PG_INGRESS_POLICY}."
