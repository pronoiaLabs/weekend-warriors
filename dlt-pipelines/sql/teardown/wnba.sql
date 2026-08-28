-- =============================================================================
-- teardown/wnba.sql -- permanently retire the WNBA stack
-- =============================================================================
-- DESTRUCTIVE: drops WNBA_DEV_DB and WNBA_PROD_DB, including every RAW table.
--
-- Run only through:
--   make teardown-source SOURCE=wnba CONFIRM=1 DROP_DATA=1
--
-- The target first reapplies sql/ops/06_dbt_harvest.sql without its retired
-- database reference. Do not run this file directly unless that procedure has
-- already been updated, or DBT_OBS_RETENTION will fail after the database drop.
--
-- This file is intentionally outside sql/sources/wnba/. setup-source executes
-- every SQL file in that directory and must never be able to discover teardown.
--
-- Rollback: Snowflake Time Travel may permit:
--   UNDROP DATABASE WNBA_PROD_DB;
--   UNDROP DATABASE WNBA_DEV_DB;
-- That restores database contents only. Tasks in DLT_DB, the DBT PROJECT,
-- CoWork registration, secret and external-access objects must be recreated
-- from the last repository revision that contained the WNBA implementation.
-- =============================================================================

-- Stop and remove the ten ingestion Tasks. Their schedules were removed from
-- the registry before retirement, so generate_tasks.py no longer emits or
-- manages them; explicit names are the only reliable cleanup.
USE ROLE DLT_LOADER_ROLE;

ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_REFERENCE SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_GAMES SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_STATS SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_PLAYS SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_STANDINGS SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_SEASON_STATS SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_ADVANCED_GAME SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_ADVANCED_SEASON SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_SHOT_LOCATIONS SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_INJURIES SUSPEND;

DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_REFERENCE;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_GAMES;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_STATS;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_PLAYS;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_STANDINGS;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_SEASON_STATS;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_ADVANCED_GAME;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_ADVANCED_SEASON;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_SHOT_LOCATIONS;
DROP TASK IF EXISTS DLT_DB.OPS.DLT_TASK_WNBA_INJURIES;

-- The triggered dbt graph is owned separately and is not generated from the
-- ingestion registry. Suspend child before root, then drop in the same order.
USE ROLE DBT_RUNNER_ROLE;

EXECUTE IMMEDIATE $$
BEGIN
  ALTER TASK IF EXISTS WNBA_PROD_DB.OPS.DBT_HARVEST_WNBA SUSPEND;
  ALTER TASK IF EXISTS WNBA_PROD_DB.OPS.DBT_BUILD_WNBA SUSPEND;
  DROP TASK IF EXISTS WNBA_PROD_DB.OPS.DBT_HARVEST_WNBA;
  DROP TASK IF EXISTS WNBA_PROD_DB.OPS.DBT_BUILD_WNBA;
  DROP STREAM IF EXISTS WNBA_PROD_DB.OPS.DBT_LOADS_STREAM;
  DROP PROCEDURE IF EXISTS WNBA_PROD_DB.OPS.SP_DBT_BUILD();
EXCEPTION
  WHEN OTHER THEN
    LET teardown_error VARCHAR := SQLERRM;
    IF (
      teardown_error ILIKE '%WNBA_PROD_DB%'
      AND teardown_error ILIKE '%does not exist%'
    ) THEN
      NULL;
    ELSE
      RAISE;
    END IF;
END;
$$;

-- Purge shared dbt observability before removing the project. Operator rows
-- carry no sport column, so identify them through DBT_QUERY_LOG first.
DELETE FROM DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS
WHERE QUERY_ID IN (
  SELECT QUERY_ID
  FROM DLT_DB.OPS.DBT_QUERY_LOG
  WHERE LOWER(SPORT) = 'wnba'
);
DELETE FROM DLT_DB.OPS.DBT_QUERY_LOG WHERE LOWER(SPORT) = 'wnba';
DELETE FROM DLT_DB.OPS.DBT_RUNS WHERE LOWER(SPORT) = 'wnba';
DELETE FROM DLT_DB.OPS.DBT_BUILDS WHERE LOWER(SPORT) = 'wnba';

DROP DBT PROJECT IF EXISTS DLT_DB.DEPLOY.CORTEX_LIFECYCLE_WNBA;

-- Remove the agent from CoWork before dropping the agent or its database.
-- ALTER SNOWFLAKE INTELLIGENCE has no IF EXISTS form, so a rerun ignores only
-- the expected "already absent" class of errors.
USE ROLE ACCOUNTADMIN;

EXECUTE IMMEDIATE $$
BEGIN
  EXECUTE IMMEDIATE
    'ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT '
    || 'DROP AGENT WNBA_PROD_DB.ANALYTICS.WNBA_ANALYST';
EXCEPTION
  WHEN OTHER THEN
    LET teardown_error VARCHAR := SQLERRM;
    IF (
      teardown_error ILIKE '%does not exist%'
      OR teardown_error ILIKE '%not registered%'
      OR teardown_error ILIKE '%not found%'
    ) THEN
      NULL;
    ELSE
      RAISE;
    END IF;
END;
$$;

USE ROLE SYSADMIN;
EXECUTE IMMEDIATE $$
BEGIN
  DROP AGENT IF EXISTS WNBA_PROD_DB.ANALYTICS.WNBA_ANALYST;
EXCEPTION
  WHEN OTHER THEN
    LET teardown_error VARCHAR := SQLERRM;
    IF (
      teardown_error ILIKE '%WNBA_PROD_DB%'
      AND teardown_error ILIKE '%does not exist%'
    ) THEN
      NULL;
    ELSE
      RAISE;
    END IF;
END;
$$;

-- Remove shared ingestion/ops records. Capture run query ids before deleting
-- the summary tables so their parsed logs and metrics can be removed too.
USE ROLE DLT_LOADER_ROLE;

CREATE OR REPLACE TEMPORARY TABLE DLT_DB.OPS.WNBA_TEARDOWN_QUERY_IDS AS
SELECT QUERY_ID
FROM DLT_DB.OPS.TASK_RUNS
WHERE LOWER(PIPELINE) LIKE 'wnba_%'
UNION
SELECT QUERY_ID
FROM DLT_DB.OPS.PIPELINE_RUNS
WHERE UPPER(SPORT) = 'WNBA';

DELETE FROM DLT_DB.OPS.LOG_LINES
WHERE QUERY_ID IN (SELECT QUERY_ID FROM DLT_DB.OPS.WNBA_TEARDOWN_QUERY_IDS);
DELETE FROM DLT_DB.OPS.METRIC_SAMPLES
WHERE QUERY_ID IN (SELECT QUERY_ID FROM DLT_DB.OPS.WNBA_TEARDOWN_QUERY_IDS);
DELETE FROM DLT_DB.OPS.PIPELINE_RUNS WHERE UPPER(SPORT) = 'WNBA';
DELETE FROM DLT_DB.OPS.TASK_RUNS WHERE LOWER(PIPELINE) LIKE 'wnba_%';
DELETE FROM DLT_DB.OPS.ALERT_STATE
WHERE LOWER(SCOPE) = 'dbt_build_wnba' OR LOWER(SCOPE) LIKE 'wnba_%';
DELETE FROM DLT_DB.OPS.HEADLINES
WHERE LOWER(COALESCE(ENTITY, '')) LIKE '%wnba%'
   OR LOWER(COALESCE(HEADLINE, '')) LIKE '%wnba%'
   OR LOWER(COALESCE(DETAIL, '')) LIKE '%wnba%';
DELETE FROM DLT_DB.OPS.PIPELINE_REGISTRY WHERE LOWER(NAME) LIKE 'wnba_%';

DROP TABLE IF EXISTS DLT_DB.OPS.WNBA_TEARDOWN_QUERY_IDS;

-- Remove credentials and egress after all objects that reference them are gone.
USE ROLE SYSADMIN;
DROP SECRET IF EXISTS DLT_DB.OPS.WNBA_API_KEY;

USE ROLE ACCOUNTADMIN;
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS WNBA_API_EAI;
DROP NETWORK RULE IF EXISTS DLT_DB.OPS.WNBA_API_EGRESS;

-- Database ownership remains with SYSADMIN even though dbt-owned child schemas
-- exist inside prod. Dropping the database removes the entire child hierarchy.
USE ROLE SYSADMIN;
DROP DATABASE IF EXISTS WNBA_PROD_DB;
DROP DATABASE IF EXISTS WNBA_DEV_DB;

-- Post-run verification. Empty result sets are success.
SHOW TASKS LIKE 'DLT_TASK_WNBA_%' IN SCHEMA DLT_DB.OPS;
SHOW DATABASES LIKE 'WNBA%';
SHOW DBT PROJECTS LIKE 'CORTEX_LIFECYCLE_WNBA' IN SCHEMA DLT_DB.DEPLOY;
SHOW AGENTS LIKE 'WNBA_ANALYST' IN ACCOUNT;
SHOW SECRETS LIKE 'WNBA_API_KEY' IN SCHEMA DLT_DB.OPS;
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'WNBA_API_EAI';
SELECT COUNT(*) AS WNBA_REGISTRY_ROWS
FROM DLT_DB.OPS.PIPELINE_REGISTRY
WHERE LOWER(NAME) LIKE 'wnba_%';
