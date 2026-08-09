-- =============================================================================
-- ops/08_cost_tags.sql
-- =============================================================================
-- Purpose       : Object tags for cost attribution: a COST_CENTER tag on the
--                 warehouses and on the dbt observability tasks, so warehouse
--                 metering can be sliced by component.
-- Run as        : SYSADMIN (tag + warehouses), then DBT_RUNNER_ROLE (its tasks)
-- Prerequisites : base/04_dbt_runner.sql, ops/06_dbt_harvest.sql and the
--                 per-sport 05_dbt_trigger.sql files (the tasks tagged below).
-- Apply         : make setup-ops CONFIRM=1  (or snow sql -f directly)
--
-- TWO TAGGING FEATURES SHARE A NAME; this file is the OBJECT-tag half.
-- QUERY_TAG (the session parameter, set per query by dbt) answers "which
-- build/model/sport was this query" -- that lives in dbt-pipelines and
-- 06_dbt_harvest.sql. Object tags answer "which component owns this
-- warehouse hour" at the metering level, where per-query attribution does
-- not reach (idle time, auto-suspend tails).
--
-- WHY WAREHOUSES AND NOT SPORTS: DBT_WH serves both sports, so sport-level
-- cost comes from QUERY_TAG rollups over DBT_QUERY_LOG, not from object
-- tags. The object tag dimension is the component: dbt / dev / ops.
--
-- DELIBERATELY NOT TAGGED: the 17 DLT_TASK_% ingestion tasks (standing rule:
-- nothing touches them outside generate_tasks.py) and the SPCS compute
-- pools (ingestion cost lives there, not in a warehouse; tagging pools is a
-- follow-up decision recorded in BACKLOG).
--
-- The cost join, when wanted (ACCOUNT_USAGE, ~2h lag, 365d):
--   SELECT tr.TAG_VALUE, DATE_TRUNC('day', wm.START_TIME) AS DAY,
--          SUM(wm.CREDITS_USED) AS CREDITS
--   FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wm
--   JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
--     ON tr.OBJECT_ID = wm.WAREHOUSE_ID AND tr.DOMAIN = 'WAREHOUSE'
--   WHERE tr.TAG_NAME = 'COST_CENTER'
--   GROUP BY 1, 2 ORDER BY 2, 1;
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: the tag and the warehouse bindings (SYSADMIN owns both sides)
-- -----------------------------------------------------------------------------

USE ROLE SYSADMIN;

CREATE TAG IF NOT EXISTS DLT_DB.OPS.COST_CENTER
  ALLOWED_VALUES 'ingestion', 'dbt', 'dev', 'ops'
  COMMENT = 'Component-level cost attribution. Joined to WAREHOUSE_METERING_HISTORY via TAG_REFERENCES; sport-level dbt cost comes from QUERY_TAG instead.';

ALTER WAREHOUSE DBT_WH         SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER WAREHOUSE DEVELOPMENT_WH SET TAG DLT_DB.OPS.COST_CENTER = 'dev';
ALTER WAREHOUSE DLT_OPS_WH     SET TAG DLT_DB.OPS.COST_CENTER = 'ops';

-- Task tagging below runs as the tasks' owner, which still needs APPLY on
-- the tag itself.
GRANT APPLY ON TAG DLT_DB.OPS.COST_CENTER TO ROLE DBT_RUNNER_ROLE;

-- -----------------------------------------------------------------------------
-- Section 2: the dbt observability tasks (owned by DBT_RUNNER_ROLE)
-- -----------------------------------------------------------------------------

USE ROLE DBT_RUNNER_ROLE;

ALTER TASK NFL_PROD_DB.OPS.DBT_BUILD_NFL     SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK NFL_PROD_DB.OPS.DBT_HARVEST_NFL   SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK WNBA_PROD_DB.OPS.DBT_BUILD_WNBA   SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK WNBA_PROD_DB.OPS.DBT_HARVEST_WNBA SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK DLT_DB.OPS.DBT_OBS_RETENTION      SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
