-- =============================================================================
-- ops/07_dbt_runs.sql
-- =============================================================================
-- Purpose       : V_DBT_RUNS -- one row per event-driven dbt build attempt,
--                 the dbt counterpart of V_TASK_RUNS. Feeds the ops
--                 dashboard's dbt page.
-- Run as        : DBT_RUNNER_ROLE (owns every underlying object and the
--                 DBT_BUILD_% tasks whose history the view reads)
-- Prerequisites : 06_dbt_harvest.sql (tables + CREATE VIEW grant), the
--                 per-sport 05_dbt_trigger.sql files (tasks + audit tables).
-- Apply         : make setup-ops CONFIRM=1  (or snow sql -f directly)
--
-- WHY THIS VIEW EXISTS: the DBT_BUILD_<SPORT> tasks are deliberately
-- invisible to V_TASK_RUNS (its DLT_TASK_% filter), and their story is
-- scattered across per-database TASK_HISTORY, ACCOUNT_USAGE.TASK_HISTORY,
-- DLT_DB.OPS.DBT_BUILDS and the harvest tables. This is the single joined
-- surface.
--
-- THE JOIN KEY IS IN THE RETURN VALUE. SP_DBT_BUILD returns
-- 'built after N load(s), build_id <uuid>', and TASK_HISTORY keeps that
-- string in RETURN_VALUE, so a task run maps to its DBT_BUILDS row (and
-- from there to every tagged query) exactly -- no time-window joins. Failed
-- builds have no DBT_BUILDS row and surface here with build columns NULL;
-- 'no-op' runs (false-positive stream evaluations) are excluded, as are
-- SKIPPED evaluations.
--
-- Sources, like V_TASK_RUNS: the per-database INFORMATION_SCHEMA
-- TASK_HISTORY function (live but 7 days) UNION ACCOUNT_USAGE.TASK_HISTORY
-- (365 days, ~45 min lag), deduped by QUERY_ID preferring the live row.
-- Adding a sport means adding one CTE branch here (the per-database
-- function cannot be parameterized over databases).
-- =============================================================================

USE ROLE DBT_RUNNER_ROLE;

CREATE OR REPLACE VIEW DLT_DB.OPS.V_DBT_RUNS
    COMMENT = 'One row per event-driven dbt build attempt, joined to its build record and per-query rollups. Spine: task history for DBT_BUILD_% tasks.'
AS
WITH

-- -----------------------------------------------------------------------------
-- 1. Live task history, one branch per sport database (7-day window, no lag).
-- -----------------------------------------------------------------------------
live_history AS (
    SELECT DATABASE_NAME, NAME, QUERY_ID, STATE, ERROR_MESSAGE, RETURN_VALUE,
           SCHEDULED_TIME, QUERY_START_TIME, COMPLETED_TIME, 1 AS SOURCE_RANK
    FROM TABLE(NFL_PROD_DB.INFORMATION_SCHEMA.TASK_HISTORY(RESULT_LIMIT => 10000))
    WHERE NAME LIKE 'DBT\_BUILD\_%' ESCAPE '\\'
    UNION ALL
    SELECT DATABASE_NAME, NAME, QUERY_ID, STATE, ERROR_MESSAGE, RETURN_VALUE,
           SCHEDULED_TIME, QUERY_START_TIME, COMPLETED_TIME, 1 AS SOURCE_RANK
    FROM TABLE(WNBA_PROD_DB.INFORMATION_SCHEMA.TASK_HISTORY(RESULT_LIMIT => 10000))
    WHERE NAME LIKE 'DBT\_BUILD\_%' ESCAPE '\\'
),

-- -----------------------------------------------------------------------------
-- 2. Account-usage task history: 365 days, ~45 min behind. The union with a
--    SOURCE_RANK dedupe means recent runs come from the live branch and old
--    ones survive the 7-day cliff.
-- -----------------------------------------------------------------------------
archive_history AS (
    SELECT DATABASE_NAME, NAME, QUERY_ID, STATE, ERROR_MESSAGE, RETURN_VALUE,
           SCHEDULED_TIME, QUERY_START_TIME, COMPLETED_TIME, 2 AS SOURCE_RANK
    FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
    WHERE NAME LIKE 'DBT\_BUILD\_%' ESCAPE '\\'
      AND DATABASE_NAME IN ('NFL_PROD_DB', 'WNBA_PROD_DB')
),

task_runs AS (
    SELECT *
    FROM (SELECT * FROM live_history UNION ALL SELECT * FROM archive_history)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY QUERY_ID ORDER BY SOURCE_RANK) = 1
),

-- -----------------------------------------------------------------------------
-- 3. Per-build query rollups from the harvest. Grouped by BUILD_ID, so a
--    build's numbers appear once the harvest child has run (minutes after
--    the build; NULL rollups on a fresh build just mean "not harvested yet").
-- -----------------------------------------------------------------------------
query_rollup AS (
    SELECT
        BUILD_ID,
        COUNT(*)                                            AS N_QUERIES,
        COUNT_IF(EXECUTION_STATUS <> 'SUCCESS')             AS N_FAILED_QUERIES,
        COUNT_IF(NODE IS NOT NULL)                          AS N_NODE_QUERIES,
        SUM(TOTAL_ELAPSED_TIME)                             AS SUM_ELAPSED_MS,
        MAX(TOTAL_ELAPSED_TIME)                             AS MAX_ELAPSED_MS,
        SUM(BYTES_SCANNED)                                  AS SUM_BYTES_SCANNED,
        SUM(ROWS_PRODUCED)                                  AS SUM_ROWS_PRODUCED
    FROM DLT_DB.OPS.DBT_QUERY_LOG
    GROUP BY BUILD_ID
)

SELECT
    -- Identity
    LOWER(REPLACE(t.DATABASE_NAME, '_PROD_DB', ''))         AS SPORT,
    t.NAME                                                  AS TASK_NAME,
    t.QUERY_ID                                              AS RUN_QUERY_ID,
    REGEXP_SUBSTR(t.RETURN_VALUE, 'build_id ([0-9a-f-]+)', 1, 1, 'e') AS BUILD_ID,

    -- Outcome
    t.STATE,
    t.ERROR_MESSAGE,
    b.ARGS,
    b.ENVIRONMENT,
    b.PROJECT_FQN,
    b.DRAINED_LOADS,
    b.EXEC_QUERY_ID,

    -- Timings
    t.SCHEDULED_TIME,
    t.QUERY_START_TIME                                      AS STARTED_AT,
    t.COMPLETED_TIME,
    DATEDIFF('second', t.QUERY_START_TIME, t.COMPLETED_TIME) AS DURATION_S,

    -- Query rollups (NULL until the harvest child lands)
    q.N_QUERIES,
    q.N_FAILED_QUERIES,
    q.N_NODE_QUERIES,
    q.SUM_ELAPSED_MS,
    q.MAX_ELAPSED_MS,
    q.SUM_BYTES_SCANNED,
    q.SUM_ROWS_PRODUCED

FROM task_runs t
LEFT JOIN DLT_DB.OPS.DBT_BUILDS b
       ON b.BUILD_ID = REGEXP_SUBSTR(t.RETURN_VALUE, 'build_id ([0-9a-f-]+)', 1, 1, 'e')
LEFT JOIN query_rollup q
       ON q.BUILD_ID = b.BUILD_ID
-- Evaluations that found nothing (SKIPPED) and false-positive no-op drains
-- are not build attempts; a real run always has a query id.
WHERE t.STATE NOT IN ('SKIPPED')
  AND COALESCE(t.RETURN_VALUE, '') NOT LIKE 'no-op%'
  AND t.QUERY_ID IS NOT NULL;

GRANT SELECT ON VIEW DLT_DB.OPS.V_DBT_RUNS TO ROLE DLT_DEV_ROLE;
