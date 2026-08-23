-- =============================================================================
-- sources/postgres/04_ingress_spcs.sql
-- Purpose : Let SPCS jobs (DLT_POOL via POSTGRES_APP_EAI) reach the Postgres
--           instance. EAI only allows the container to *try*; the instance
--           POSTGRES_INGRESS policy still has to accept the source IPs.
--           Laptop-only 108.214.39.72/32 is why the first Task fire timed out
--           on :5432 (2026-08-23). Do not add 0.0.0.0/0.
-- Run as  : ACCOUNTADMIN (policy is ACCOUNTADMIN-owned)
-- Apply   : make setup-source SOURCE=postgres CONFIRM=1
--           (or snow sql -c weekend-warriors -f this file)
--
-- IPs from SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES() (us-east-2). They expire;
-- re-run the function and ALTER this rule when Snowflake publishes new ones.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE NETWORK RULE IF NOT EXISTS DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS
  TYPE = IPV4
  VALUE_LIST = ('153.45.34.0/24', '153.45.77.0/24')
  MODE = POSTGRES_INGRESS
  COMMENT = 'Snowflake egress CIDRs (SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES) so SPCS can open :5432 on the Weekend Warrior App instance.';

ALTER NETWORK RULE DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS
  SET VALUE_LIST = ('153.45.34.0/24', '153.45.77.0/24');

-- Keep the laptop /32 rule. ADD, do not SET (SET would drop it).
ALTER NETWORK POLICY POSTGRES_INGRESS_POLICY_WEEKEND_WARRIOR_APP
  ADD ALLOWED_NETWORK_RULE_LIST = ('DLT_DB.OPS.POSTGRES_INGRESS_SNOWFLAKE_EGRESS');
