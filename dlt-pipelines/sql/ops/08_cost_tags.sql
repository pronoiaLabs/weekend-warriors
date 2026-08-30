-- =============================================================================
-- ops/08_cost_tags.sql
-- =============================================================================
-- Purpose       : Object tags for cost attribution: a COST_CENTER tag on every
--                 billable compute container (warehouses, SPCS pools), every
--                 scheduled task, and the event table, so metering can be
--                 sliced by component.
-- Run as        : SYSADMIN (tag, warehouses, pools, event table, grants), then
--                 DLT_LOADER_ROLE (its ops tasks), then DBT_RUNNER_ROLE (its
--                 tasks).
-- Prerequisites : base/04_dbt_runner.sql, prod/02_compute.sql,
--                 dev/02_compute.sql, ops/01..07, and the per-sport
--                 05_dbt_trigger.sql files (the objects tagged below).
-- Apply         : make setup-ops CONFIRM=1  (or snow sql -f directly)
--
-- TWO TAGGING FEATURES SHARE A NAME; this file is the OBJECT-tag half.
-- QUERY_TAG (the session parameter, set per query by dbt) answers "which
-- build/model/sport was this query" -- that lives in dbt-pipelines and
-- 06_dbt_harvest.sql. Object tags answer "which component owns this
-- warehouse hour" at the metering level, where per-query attribution does
-- not reach (idle time, auto-suspend tails).
--
-- ONE JOB WAREHOUSE (2026-08): DLT_WH runs ingestion, dbt, and ops, so
-- warehouse-level metering no longer separates components -- that was the
-- explicit trade for eliminating per-warehouse wake overhead (three XS
-- warehouses spent ~2/3 of metered compute on resume minimums and suspend
-- tails). Component cost now reads off the TASK tags below joined to
-- TASK_HISTORY / QUERY_ATTRIBUTION_HISTORY, and sport-level dbt cost from
-- QUERY_TAG rollups over DBT_QUERY_LOG, as before. The tag still follows
-- the compute an object burns, not its domain.
--
-- TAGGED ELSEWHERE: the DLT_TASK_% ingestion tasks carry 'ingestion', set by
-- deploy/tasks/generate_tasks.py inside build/tasks.sql (standing rule:
-- nothing touches those tasks outside the generator). CREATE OR ALTER TASK
-- preserves existing tags, and the generator re-asserts the tag on every
-- apply anyway, so a new pipeline's Task is tagged from its first deploy.
--
-- DELIBERATELY NOT TAGGED: the ops views (CREATE OR REPLACE drops tags, so a
-- view tag silently falls off on the next re-apply of 02/03/04/07 and would
-- look authoritative while stale) and the ops tables other than DLT_EVENTS
-- (no metering join reaches a table; a tag there is discoverability alone,
-- at the price of a permanent line here for every future table). DLT_EVENTS
-- is the one exception: the largest ops object by storage, with stable DDL,
-- and it anchors 'ops' for a future TABLE_STORAGE_METRICS join.
--
-- The cost join, when wanted (ACCOUNT_USAGE, ~2h lag, 365d). Warehouses join
-- by id; the pool leg joins by NAME, because
-- SNOWPARK_CONTAINER_SERVICES_HISTORY carries only COMPUTE_POOL_NAME:
--   SELECT tr.TAG_VALUE, DATE_TRUNC('day', wm.START_TIME) AS DAY,
--          SUM(wm.CREDITS_USED) AS CREDITS
--   FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wm
--   JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
--     ON tr.OBJECT_ID = wm.WAREHOUSE_ID AND tr.DOMAIN = 'WAREHOUSE'
--   WHERE tr.TAG_NAME = 'COST_CENTER'
--   GROUP BY 1, 2
--   UNION ALL
--   SELECT tr.TAG_VALUE, DATE_TRUNC('day', sh.START_TIME),
--          SUM(sh.CREDITS_USED)
--   FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY sh
--   JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
--     ON tr.OBJECT_NAME = sh.COMPUTE_POOL_NAME AND tr.DOMAIN = 'COMPUTE POOL'
--   WHERE tr.TAG_NAME = 'COST_CENTER'
--   GROUP BY 1, 2
--   ORDER BY 2, 1;
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: the tag, the compute containers, the event table (SYSADMIN owns
-- all of them), and the APPLY grants the later sections depend on
-- -----------------------------------------------------------------------------

USE ROLE SYSADMIN;

CREATE TAG IF NOT EXISTS DLT_DB.OPS.COST_CENTER
  ALLOWED_VALUES 'ingestion', 'dbt', 'dev', 'ops', 'jobs'
  COMMENT = 'Component-level cost attribution. Joined to WAREHOUSE_METERING_HISTORY and SNOWPARK_CONTAINER_SERVICES_HISTORY via TAG_REFERENCES; sport-level dbt cost comes from QUERY_TAG instead.';

-- ALLOWED_VALUES on an existing tag: ALTER TAG DLT_DB.OPS.COST_CENTER ADD
-- ALLOWED_VALUES 'jobs'; is the live migration (CREATE IF NOT EXISTS skips).
ALTER WAREHOUSE DLT_WH         SET TAG DLT_DB.OPS.COST_CENTER = 'jobs';
ALTER WAREHOUSE DEVELOPMENT_WH SET TAG DLT_DB.OPS.COST_CENTER = 'dev';
ALTER WAREHOUSE DLT_DEV_WH     SET TAG DLT_DB.OPS.COST_CENTER = 'dev';

-- The pools are where ingestion cost actually lives; DLT_WH only carries the
-- tasks' MERGE queries.
ALTER COMPUTE POOL DLT_POOL     SET TAG DLT_DB.OPS.COST_CENTER = 'ingestion';
ALTER COMPUTE POOL DLT_DEV_POOL SET TAG DLT_DB.OPS.COST_CENTER = 'dev';
-- Created by sql/dev/02_compute.sql (setup-dev). Same prerequisite as DLT_DEV_POOL:
-- this file fails if setup-ops is applied before setup-dev.
ALTER COMPUTE POOL ML_DEV_POOL  SET TAG DLT_DB.OPS.COST_CENTER = 'dev';

ALTER TABLE DLT_DB.OPS.DLT_EVENTS SET TAG DLT_DB.OPS.COST_CENTER = 'ops';

-- Task tagging below runs as each task's owner, which still needs APPLY on
-- the tag itself. The DLT_LOADER_ROLE grant also covers the ALTER TASK ...
-- SET TAG lines in build/tasks.sql: without it, tasks-apply fails on the
-- first tag statement and leaves the fleet suspended mid-apply.
GRANT APPLY ON TAG DLT_DB.OPS.COST_CENTER TO ROLE DBT_RUNNER_ROLE;
GRANT APPLY ON TAG DLT_DB.OPS.COST_CENTER TO ROLE DLT_LOADER_ROLE;

-- -----------------------------------------------------------------------------
-- Section 2: the observability tasks owned by DLT_LOADER_ROLE (ops/04, ops/05)
-- -----------------------------------------------------------------------------

USE ROLE DLT_LOADER_ROLE;

ALTER TASK DLT_DB.OPS.OBS_REFRESH          SET TAG DLT_DB.OPS.COST_CENTER = 'ops';
ALTER TASK DLT_DB.OPS.OBS_REFRESH_SWEEP    SET TAG DLT_DB.OPS.COST_CENTER = 'ops';
ALTER TASK DLT_DB.OPS.DLT_EVENTS_RETENTION SET TAG DLT_DB.OPS.COST_CENTER = 'ops';
ALTER TASK DLT_DB.OPS.OBS_RETENTION        SET TAG DLT_DB.OPS.COST_CENTER = 'ops';

-- -----------------------------------------------------------------------------
-- Section 3: the tasks owned by DBT_RUNNER_ROLE (per-sport triggers, ops/06,
-- ops/07)
-- -----------------------------------------------------------------------------

USE ROLE DBT_RUNNER_ROLE;

ALTER TASK NFL_PROD_DB.OPS.DBT_BUILD_NFL     SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK NFL_PROD_DB.OPS.DBT_HARVEST_NFL   SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK NFL_PROD_DB.OPS.DBT_TEST_NFL      SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK NCAAF_PROD_DB.OPS.DBT_BUILD_NCAAF   SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK NCAAF_PROD_DB.OPS.DBT_HARVEST_NCAAF SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK NCAAF_PROD_DB.OPS.DBT_TEST_NCAAF    SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';
ALTER TASK DLT_DB.OPS.DBT_OBS_RETENTION      SET TAG DLT_DB.OPS.COST_CENTER = 'dbt';

-- 'ops', not 'dbt': they are observability machinery. See ONE JOB WAREHOUSE.
ALTER TASK DLT_DB.OPS.DBT_RUNS_REFRESH SET TAG DLT_DB.OPS.COST_CENTER = 'ops';
ALTER TASK DLT_DB.OPS.DBT_RUNS_SWEEP   SET TAG DLT_DB.OPS.COST_CENTER = 'ops';
