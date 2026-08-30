-- =============================================================================
-- ops/07_dbt_runs.sql
-- =============================================================================
-- Purpose       : DBT_RUNS -- one row per event-driven dbt build attempt, as a
--                 REAL TABLE, the dbt counterpart of PIPELINE_RUNS. V_DBT_RUNS
--                 survives as a thin passthrough; the dashboard's /dbt page
--                 does not change.
-- Run as        : DBT_RUNNER_ROLE (owns every underlying object and the
--                 DBT_BUILD_% tasks whose history the refresh reads), with a
--                 SYSADMIN + ACCOUNTADMIN grant slice up front.
-- Prerequisites : 06_dbt_harvest.sql (tables + schema grants incl. CREATE
--                 STREAM), the per-sport 05_dbt_trigger.sql files.
-- Apply         : make setup-ops CONFIRM=1  (or snow sql -f directly)
--
-- WHY A TABLE: the view this file used to hold cost ~6.5s server-side per
-- cold dashboard query (1.4s compile + 5.2s exec), re-planning three
-- per-sport TASK_HISTORY() calls, an ACCOUNT_USAGE union and per-build
-- rollups on every read. Same disease the pipeline-run stack had, same cure:
-- the joins now run once per data arrival in SP_DBT_RUNS_REFRESH, and reads
-- are a table scan. It also killed a chore: the view hardcoded one CTE branch
-- per sport ("adding a sport means adding one CTE branch here") -- needlessly,
-- it turned out, because INFORMATION_SCHEMA.TASK_HISTORY is ACCOUNT-WIDE (see
-- Step 3's note). The refresh is name-pattern-driven (DBT_BUILD_% in any
-- *_PROD_DB), so sport N+1 needs ZERO edits in this file.
--
-- THE JOIN KEY IS IN THE RETURN VALUE, unchanged: SP_DBT_BUILD returns
-- 'built after N load(s), build_id <uuid>', TASK_HISTORY keeps that string in
-- RETURN_VALUE, and a task run maps to its DBT_BUILDS row (and from there to
-- every tagged query) exactly -- no time-window joins. Failed builds have no
-- DBT_BUILDS row and surface with build columns NULL.
--
-- THE REFRESH MODEL mirrors OBS_REFRESH (ops/04), including its two verified
-- traps: EXECUTE TASK does not bypass a triggered task's WHEN (so the sweep
-- calls the proc directly behind an in-flight check), and a task session runs
-- the owner's PRIMARY role alone (so the ACCOUNT_USAGE grant below is
-- explicit; the old view "working" proved nothing, since interactive sessions
-- carry secondary roles).
--
-- WHAT FIRES IT: two APPEND_ONLY streams. DBT_BUILDS gets an INSERT per
-- successful build (from SP_DBT_BUILD, seconds after the build ends), so the
-- run row appears within ~a minute of build completion. DBT_QUERY_LOG gets
-- MERGE-inserted rows when the harvest lands minutes later, firing a second
-- refresh that fills the rollups. APPEND_ONLY is REQUIRED, not preferred:
-- the harvest also UPDATEs STATS_CAPTURED on up to 200 DBT_QUERY_LOG rows per
-- run, and a standard stream would re-fire the refresh on every one of them.
-- FAILED builds write no row anywhere (SP_DBT_BUILD lets the error propagate)
-- and never harvest, so they are the zero-event case: DBT_RUNS_SWEEP (every
-- 4h, staggered :30 from OBS_REFRESH_SWEEP) bounds how long they can sit
-- unrecorded. A fire can also catch a build mid-EXECUTING with a NULL
-- RETURN_VALUE; the harvest-triggered second fire self-heals the row.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: grant slice
-- -----------------------------------------------------------------------------

USE ROLE SYSADMIN;

-- The refresh and sweep tasks run on DLT_WH, the single job warehouse;
-- DBT_RUNNER_ROLE's USAGE + OPERATE on it comes from sql/prod/02_compute.sql,
-- so no warehouse grant is needed here.

-- A task session runs the owner's PRIMARY role alone, so interactive testing
-- (which carries secondary roles) cannot prove this privilege exists; the
-- OBS_REFRESH bootstrap failed live on exactly this gap for DLT_LOADER_ROLE
-- (2026-08-09). IMPORTED PRIVILEGES is the only grantable privilege on a
-- shared database.
USE ROLE ACCOUNTADMIN;
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE DBT_RUNNER_ROLE;
USE ROLE SYSADMIN;

-- -----------------------------------------------------------------------------
-- Section 2: tables and streams, owned by DBT_RUNNER_ROLE
-- -----------------------------------------------------------------------------

USE ROLE DBT_RUNNER_ROLE;

-- Streams need change tracking on their source, and creating a stream does
-- not enable it. Explicit, as the table owner (the 05_dbt_trigger precedent).
ALTER TABLE DLT_DB.OPS.DBT_BUILDS SET CHANGE_TRACKING = TRUE;
ALTER TABLE DLT_DB.OPS.DBT_QUERY_LOG SET CHANGE_TRACKING = TRUE;

-- One row per build attempt. Column set is the old view's output plus
-- RETURN_VALUE (the thin view's no-op filter needs it) and REFRESHED_AT.
-- IF NOT EXISTS, never OR REPLACE: this table outlives the 7-day live
-- task-history window it is built from.
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.DBT_RUNS (
    SPORT             VARCHAR,        -- lowercase stem ('nfl'), as the view spelled it
    TASK_NAME         VARCHAR,
    RUN_QUERY_ID      VARCHAR,        -- the key
    BUILD_ID          VARCHAR,
    RETURN_VALUE      VARCHAR,
    STATE             VARCHAR,
    ERROR_MESSAGE     VARCHAR,
    ARGS              VARCHAR,
    ENVIRONMENT       VARCHAR,
    PROJECT_FQN       VARCHAR,
    DRAINED_LOADS     NUMBER,
    EXEC_QUERY_ID     VARCHAR,
    SCHEDULED_TIME    TIMESTAMP_LTZ,
    STARTED_AT        TIMESTAMP_LTZ,
    COMPLETED_TIME    TIMESTAMP_LTZ,
    DURATION_S        NUMBER,
    N_QUERIES         NUMBER,
    N_FAILED_QUERIES  NUMBER,
    N_NODE_QUERIES    NUMBER,
    SUM_ELAPSED_MS    NUMBER,
    MAX_ELAPSED_MS    NUMBER,
    SUM_BYTES_SCANNED NUMBER,
    SUM_ROWS_PRODUCED NUMBER,
    REFRESHED_AT      TIMESTAMP_LTZ
)
COMMENT = 'One row per event-driven dbt build attempt, incl. EXECUTING and FAILED. Maintained by SP_DBT_RUNS_REFRESH; read through V_DBT_RUNS. Retention 365d (SP_DBT_OBS_RETENTION).';

-- The drain target. Stream consumption requires DML that reads the stream;
-- the counts are bookkeeping, the consumption is the point.
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.DBT_RUNS_REFRESH_LOG (
    FIRED_AT    TIMESTAMP_LTZ,
    STREAM_NAME VARCHAR,
    EVENTS      NUMBER
)
COMMENT = 'One row per stream per SP_DBT_RUNS_REFRESH fire: how many new events each drain consumed. Retention 365d.';

-- One stream per consumer (ops/02's rule). SHOW_INITIAL_ROWS is not the data
-- source here (the merges read task history, not the streams) -- it is the
-- IGNITION: without it a fresh stream is empty, SYSTEM$STREAM_HAS_DATA is
-- false, and nothing fires the bootstrap until the next build or sweep tick.
-- IF NOT EXISTS, never OR REPLACE (replacing re-arms the initial emission).
CREATE STREAM IF NOT EXISTS DLT_DB.OPS.STREAM_DBT_BUILDS
    ON TABLE DLT_DB.OPS.DBT_BUILDS
    APPEND_ONLY = TRUE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'Fires DBT_RUNS_REFRESH when a successful build lands. APPEND_ONLY: retention DELETEs must stay invisible.';

CREATE STREAM IF NOT EXISTS DLT_DB.OPS.STREAM_DBT_QUERY_LOG
    ON TABLE DLT_DB.OPS.DBT_QUERY_LOG
    APPEND_ONLY = TRUE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'Fires DBT_RUNS_REFRESH when a harvest lands (fills rollups). APPEND_ONLY is REQUIRED: the harvest UPDATEs STATS_CAPTURED on up to 200 rows per run.';

-- -----------------------------------------------------------------------------
-- Section 3: the refresh procedure
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_DBT_RUNS_REFRESH(FULL_REBUILD BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Drain the trigger streams, then re-merge DBT_RUNS from task history (live per sport via the registry; ACCOUNT_USAGE at bootstrap or after a gap) and the harvest rollups.'
EXECUTE AS CALLER
AS
$$
DECLARE
  builds_n INTEGER DEFAULT 0;
  qlog_n   INTEGER DEFAULT 0;
  merged_n INTEGER DEFAULT 0;
  use_hist BOOLEAN;
  wm       TIMESTAMP_LTZ;
BEGIN

  -- -------------------------------------------------------------------------
  -- Step 1: consume both streams. A plain SELECT does not advance a stream;
  -- only DML does, so each INSERT below IS the consumption that stops the
  -- task re-firing. The pre-counts are read non-consumingly for the return
  -- string. Empty streams are NOT a no-op: the sweep exists precisely to
  -- record runs that produced no stream event, so the merges always run.
  -- -------------------------------------------------------------------------
  builds_n := (SELECT COUNT(*) FROM DLT_DB.OPS.STREAM_DBT_BUILDS);
  qlog_n   := (SELECT COUNT(*) FROM DLT_DB.OPS.STREAM_DBT_QUERY_LOG);

  INSERT INTO DLT_DB.OPS.DBT_RUNS_REFRESH_LOG (FIRED_AT, STREAM_NAME, EVENTS)
    SELECT CURRENT_TIMESTAMP(), 'STREAM_DBT_BUILDS', COUNT(*)
    FROM DLT_DB.OPS.STREAM_DBT_BUILDS;
  INSERT INTO DLT_DB.OPS.DBT_RUNS_REFRESH_LOG (FIRED_AT, STREAM_NAME, EVENTS)
    SELECT CURRENT_TIMESTAMP(), 'STREAM_DBT_QUERY_LOG', COUNT(*)
    FROM DLT_DB.OPS.STREAM_DBT_QUERY_LOG;

  -- -------------------------------------------------------------------------
  -- Step 2: ACCOUNT_USAGE arm, bootstrap / gap-healing only (watermark NULL
  -- or >6 days stale: the refresh tasks were down while builds kept running,
  -- and runs would otherwise age past the live function's 7-day window).
  -- Runs FIRST so the live arms win overlap. Window 365d, matching this
  -- table's retention: a wider window would resurrect rows the weekly sweep
  -- just deleted.
  --
  -- THE ROLLUP COALESCE IS A GUARD, NOT A STYLE CHOICE: DBT_QUERY_LOG keeps
  -- 90 days but this table keeps 365, so a stale-watermark refire would
  -- recompute NULL rollups for 90-365d-old builds and overwrite the stored
  -- numbers. COALESCE keeps the stored value when the recompute comes back
  -- empty. (Build columns need no guard: DBT_BUILDS retention matches.)
  -- -------------------------------------------------------------------------
  wm := (SELECT MAX(STARTED_AT) FROM DLT_DB.OPS.DBT_RUNS);
  use_hist := (FULL_REBUILD OR wm IS NULL OR wm < DATEADD('day', -6, CURRENT_TIMESTAMP()));

  IF (use_hist) THEN
    MERGE INTO DLT_DB.OPS.DBT_RUNS tr
    USING (
      WITH th AS (
        SELECT DATABASE_NAME, NAME, QUERY_ID, STATE, ERROR_MESSAGE, RETURN_VALUE,
               SCHEDULED_TIME, QUERY_START_TIME, COMPLETED_TIME
        FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
        WHERE STARTSWITH(NAME, 'DBT_BUILD_')
          AND ENDSWITH(DATABASE_NAME, '_PROD_DB')
          AND QUERY_ID IS NOT NULL
          AND QUERY_START_TIME >= DATEADD('day', -365, CURRENT_TIMESTAMP())
        QUALIFY ROW_NUMBER() OVER (PARTITION BY QUERY_ID ORDER BY SCHEDULED_TIME DESC) = 1
      ),
      q AS (
        SELECT BUILD_ID,
               COUNT(*)                                AS N_QUERIES,
               COUNT_IF(EXECUTION_STATUS <> 'SUCCESS') AS N_FAILED_QUERIES,
               COUNT_IF(NODE IS NOT NULL)              AS N_NODE_QUERIES,
               SUM(TOTAL_ELAPSED_TIME)                 AS SUM_ELAPSED_MS,
               MAX(TOTAL_ELAPSED_TIME)                 AS MAX_ELAPSED_MS,
               SUM(BYTES_SCANNED)                      AS SUM_BYTES_SCANNED,
               SUM(ROWS_PRODUCED)                      AS SUM_ROWS_PRODUCED
        FROM DLT_DB.OPS.DBT_QUERY_LOG
        GROUP BY BUILD_ID
      )
      SELECT
        LOWER(REPLACE(th.DATABASE_NAME, '_PROD_DB', ''))                    AS SPORT,
        th.NAME                                                             AS TASK_NAME,
        th.QUERY_ID                                                         AS RUN_QUERY_ID,
        REGEXP_SUBSTR(th.RETURN_VALUE, 'build_id ([0-9a-f-]+)', 1, 1, 'e')  AS BUILD_ID,
        th.RETURN_VALUE, th.STATE, th.ERROR_MESSAGE,
        b.ARGS, b.ENVIRONMENT, b.PROJECT_FQN, b.DRAINED_LOADS, b.EXEC_QUERY_ID,
        th.SCHEDULED_TIME,
        th.QUERY_START_TIME                                                 AS STARTED_AT,
        th.COMPLETED_TIME,
        DATEDIFF('second', th.QUERY_START_TIME, th.COMPLETED_TIME)          AS DURATION_S,
        q.N_QUERIES, q.N_FAILED_QUERIES, q.N_NODE_QUERIES,
        q.SUM_ELAPSED_MS, q.MAX_ELAPSED_MS, q.SUM_BYTES_SCANNED, q.SUM_ROWS_PRODUCED
      FROM th
      LEFT JOIN DLT_DB.OPS.DBT_BUILDS b
             ON b.BUILD_ID = REGEXP_SUBSTR(th.RETURN_VALUE, 'build_id ([0-9a-f-]+)', 1, 1, 'e')
      LEFT JOIN q ON q.BUILD_ID = b.BUILD_ID
    ) s
    ON tr.RUN_QUERY_ID = s.RUN_QUERY_ID
    WHEN MATCHED THEN UPDATE SET
      SPORT = s.SPORT, TASK_NAME = s.TASK_NAME, BUILD_ID = s.BUILD_ID,
      RETURN_VALUE = s.RETURN_VALUE, STATE = s.STATE, ERROR_MESSAGE = s.ERROR_MESSAGE,
      ARGS = s.ARGS, ENVIRONMENT = s.ENVIRONMENT, PROJECT_FQN = s.PROJECT_FQN,
      DRAINED_LOADS = s.DRAINED_LOADS, EXEC_QUERY_ID = s.EXEC_QUERY_ID,
      SCHEDULED_TIME = s.SCHEDULED_TIME, STARTED_AT = s.STARTED_AT,
      COMPLETED_TIME = s.COMPLETED_TIME, DURATION_S = s.DURATION_S,
      N_QUERIES         = COALESCE(s.N_QUERIES,         tr.N_QUERIES),
      N_FAILED_QUERIES  = COALESCE(s.N_FAILED_QUERIES,  tr.N_FAILED_QUERIES),
      N_NODE_QUERIES    = COALESCE(s.N_NODE_QUERIES,    tr.N_NODE_QUERIES),
      SUM_ELAPSED_MS    = COALESCE(s.SUM_ELAPSED_MS,    tr.SUM_ELAPSED_MS),
      MAX_ELAPSED_MS    = COALESCE(s.MAX_ELAPSED_MS,    tr.MAX_ELAPSED_MS),
      SUM_BYTES_SCANNED = COALESCE(s.SUM_BYTES_SCANNED, tr.SUM_BYTES_SCANNED),
      SUM_ROWS_PRODUCED = COALESCE(s.SUM_ROWS_PRODUCED, tr.SUM_ROWS_PRODUCED),
      REFRESHED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
      (SPORT, TASK_NAME, RUN_QUERY_ID, BUILD_ID, RETURN_VALUE, STATE, ERROR_MESSAGE,
       ARGS, ENVIRONMENT, PROJECT_FQN, DRAINED_LOADS, EXEC_QUERY_ID,
       SCHEDULED_TIME, STARTED_AT, COMPLETED_TIME, DURATION_S,
       N_QUERIES, N_FAILED_QUERIES, N_NODE_QUERIES, SUM_ELAPSED_MS,
       MAX_ELAPSED_MS, SUM_BYTES_SCANNED, SUM_ROWS_PRODUCED, REFRESHED_AT)
    VALUES
      (s.SPORT, s.TASK_NAME, s.RUN_QUERY_ID, s.BUILD_ID, s.RETURN_VALUE, s.STATE, s.ERROR_MESSAGE,
       s.ARGS, s.ENVIRONMENT, s.PROJECT_FQN, s.DRAINED_LOADS, s.EXEC_QUERY_ID,
       s.SCHEDULED_TIME, s.STARTED_AT, s.COMPLETED_TIME, s.DURATION_S,
       s.N_QUERIES, s.N_FAILED_QUERIES, s.N_NODE_QUERIES, s.SUM_ELAPSED_MS,
       s.MAX_ELAPSED_MS, s.SUM_BYTES_SCANNED, s.SUM_ROWS_PRODUCED, CURRENT_TIMESTAMP());
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 3: the live arm, ONE merge for every sport.
  --
  -- INFORMATION_SCHEMA.TASK_HISTORY IS ACCOUNT-WIDE. The database qualifier
  -- only chooses which schema resolves the FUNCTION; the result set is task
  -- history for every task the role can see, account-wide. Found live
  -- 2026-08-10: a first draft looped one merge per sport database, stamping
  -- SPORT from the loop variable -- every arm matched ALL rows and the last
  -- arm relabeled the whole table with the last sport. (The old view's three per-database
  -- branches were the same misunderstanding in benign form: three identical
  -- account-wide scans, deduped -- correct output, 3x the cost.) SPORT must
  -- derive from the row's own DATABASE_NAME, exactly as the archive arm does.
  --
  -- Source filter is ONLY "QUERY_ID IS NOT NULL" (future SCHEDULED rows have
  -- none). The SKIPPED / no-op filters live in the thin view: filtering them
  -- out of the SOURCE would orphan a row captured mid-EXECUTING that later
  -- completes as a no-op, leaving a phantom running build in the table.
  -- -------------------------------------------------------------------------
  MERGE INTO DLT_DB.OPS.DBT_RUNS tr
  USING (
    WITH th AS (
      SELECT DATABASE_NAME, NAME, QUERY_ID, STATE, ERROR_MESSAGE, RETURN_VALUE,
             SCHEDULED_TIME, QUERY_START_TIME, COMPLETED_TIME
      FROM TABLE(DLT_DB.INFORMATION_SCHEMA.TASK_HISTORY(RESULT_LIMIT => 10000))
      WHERE STARTSWITH(NAME, 'DBT_BUILD_')
        AND ENDSWITH(DATABASE_NAME, '_PROD_DB')
        AND QUERY_ID IS NOT NULL
      QUALIFY ROW_NUMBER() OVER (PARTITION BY QUERY_ID ORDER BY SCHEDULED_TIME DESC) = 1
    ),
    q AS (
      SELECT BUILD_ID,
             COUNT(*)                                AS N_QUERIES,
             COUNT_IF(EXECUTION_STATUS <> 'SUCCESS') AS N_FAILED_QUERIES,
             COUNT_IF(NODE IS NOT NULL)              AS N_NODE_QUERIES,
             SUM(TOTAL_ELAPSED_TIME)                 AS SUM_ELAPSED_MS,
             MAX(TOTAL_ELAPSED_TIME)                 AS MAX_ELAPSED_MS,
             SUM(BYTES_SCANNED)                      AS SUM_BYTES_SCANNED,
             SUM(ROWS_PRODUCED)                      AS SUM_ROWS_PRODUCED
      FROM DLT_DB.OPS.DBT_QUERY_LOG
      GROUP BY BUILD_ID
    )
    SELECT
      LOWER(REPLACE(th.DATABASE_NAME, '_PROD_DB', ''))                    AS SPORT,
      th.NAME                                                             AS TASK_NAME,
      th.QUERY_ID                                                         AS RUN_QUERY_ID,
      REGEXP_SUBSTR(th.RETURN_VALUE, 'build_id ([0-9a-f-]+)', 1, 1, 'e')  AS BUILD_ID,
      th.RETURN_VALUE, th.STATE, th.ERROR_MESSAGE,
      b.ARGS, b.ENVIRONMENT, b.PROJECT_FQN, b.DRAINED_LOADS, b.EXEC_QUERY_ID,
      th.SCHEDULED_TIME,
      th.QUERY_START_TIME                                                 AS STARTED_AT,
      th.COMPLETED_TIME,
      DATEDIFF('second', th.QUERY_START_TIME, th.COMPLETED_TIME)          AS DURATION_S,
      q.N_QUERIES, q.N_FAILED_QUERIES, q.N_NODE_QUERIES,
      q.SUM_ELAPSED_MS, q.MAX_ELAPSED_MS, q.SUM_BYTES_SCANNED, q.SUM_ROWS_PRODUCED
    FROM th
    LEFT JOIN DLT_DB.OPS.DBT_BUILDS b
           ON b.BUILD_ID = REGEXP_SUBSTR(th.RETURN_VALUE, 'build_id ([0-9a-f-]+)', 1, 1, 'e')
    LEFT JOIN q ON q.BUILD_ID = b.BUILD_ID
  ) s
  ON tr.RUN_QUERY_ID = s.RUN_QUERY_ID
  WHEN MATCHED THEN UPDATE SET
    SPORT = s.SPORT, TASK_NAME = s.TASK_NAME, BUILD_ID = s.BUILD_ID,
    RETURN_VALUE = s.RETURN_VALUE, STATE = s.STATE, ERROR_MESSAGE = s.ERROR_MESSAGE,
    ARGS = s.ARGS, ENVIRONMENT = s.ENVIRONMENT, PROJECT_FQN = s.PROJECT_FQN,
    DRAINED_LOADS = s.DRAINED_LOADS, EXEC_QUERY_ID = s.EXEC_QUERY_ID,
    SCHEDULED_TIME = s.SCHEDULED_TIME, STARTED_AT = s.STARTED_AT,
    COMPLETED_TIME = s.COMPLETED_TIME, DURATION_S = s.DURATION_S,
    N_QUERIES         = COALESCE(s.N_QUERIES,         tr.N_QUERIES),
    N_FAILED_QUERIES  = COALESCE(s.N_FAILED_QUERIES,  tr.N_FAILED_QUERIES),
    N_NODE_QUERIES    = COALESCE(s.N_NODE_QUERIES,    tr.N_NODE_QUERIES),
    SUM_ELAPSED_MS    = COALESCE(s.SUM_ELAPSED_MS,    tr.SUM_ELAPSED_MS),
    MAX_ELAPSED_MS    = COALESCE(s.MAX_ELAPSED_MS,    tr.MAX_ELAPSED_MS),
    SUM_BYTES_SCANNED = COALESCE(s.SUM_BYTES_SCANNED, tr.SUM_BYTES_SCANNED),
    SUM_ROWS_PRODUCED = COALESCE(s.SUM_ROWS_PRODUCED, tr.SUM_ROWS_PRODUCED),
    REFRESHED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT
    (SPORT, TASK_NAME, RUN_QUERY_ID, BUILD_ID, RETURN_VALUE, STATE, ERROR_MESSAGE,
     ARGS, ENVIRONMENT, PROJECT_FQN, DRAINED_LOADS, EXEC_QUERY_ID,
     SCHEDULED_TIME, STARTED_AT, COMPLETED_TIME, DURATION_S,
     N_QUERIES, N_FAILED_QUERIES, N_NODE_QUERIES, SUM_ELAPSED_MS,
     MAX_ELAPSED_MS, SUM_BYTES_SCANNED, SUM_ROWS_PRODUCED, REFRESHED_AT)
  VALUES
    (s.SPORT, s.TASK_NAME, s.RUN_QUERY_ID, s.BUILD_ID, s.RETURN_VALUE, s.STATE, s.ERROR_MESSAGE,
     s.ARGS, s.ENVIRONMENT, s.PROJECT_FQN, s.DRAINED_LOADS, s.EXEC_QUERY_ID,
     s.SCHEDULED_TIME, s.STARTED_AT, s.COMPLETED_TIME, s.DURATION_S,
     s.N_QUERIES, s.N_FAILED_QUERIES, s.N_NODE_QUERIES, s.SUM_ELAPSED_MS,
     s.MAX_ELAPSED_MS, s.SUM_BYTES_SCANNED, s.SUM_ROWS_PRODUCED, CURRENT_TIMESTAMP());
  merged_n := SQLROWCOUNT;

  -- TASK_HISTORY.RETURN_VALUE comes only from SYSTEM$SET_RETURN_VALUE, which
  -- demands a constant and errors outside a task (both verified on
  -- SP_DBT_BUILD), hence the assembled literal and the guard.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT SYSTEM$SET_RETURN_VALUE(''builds +' || builds_n
      || ', qlog +' || qlog_n || ', merged ' || merged_n
      || IFF(use_hist, ' (account_usage backfill ran)', '') || ''')';
  EXCEPTION
    WHEN OTHER THEN
      NULL;
  END;

  RETURN 'builds +' || builds_n || ', qlog +' || qlog_n
      || ', merged ' || merged_n
      || IFF(use_hist, ' (account_usage backfill ran)', '');
END;
$$;

-- -----------------------------------------------------------------------------
-- Section 4: the sweep. Same solved shape as SP_OBS_SWEEP: EXECUTE TASK does
-- NOT bypass a triggered task's WHEN (verified live 2026-08-09; manual fires
-- land SKIPPED on empty streams), so the sweep calls the proc directly behind
-- an in-flight check. Covers the zero-event case: FAILED builds write no
-- DBT_BUILDS row and never harvest.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_DBT_RUNS_SWEEP()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Timed backstop for builds that write no stream event (FAILED builds): runs SP_DBT_RUNS_REFRESH unless a triggered fire is in flight.'
EXECUTE AS CALLER
AS
$$
DECLARE
  inflight INTEGER;
BEGIN
  inflight := (SELECT COUNT(*)
               FROM TABLE(DLT_DB.INFORMATION_SCHEMA.TASK_HISTORY(
                 TASK_NAME => 'DBT_RUNS_REFRESH', RESULT_LIMIT => 10))
               WHERE STATE IN ('EXECUTING', 'SCHEDULED'));
  IF (inflight > 0) THEN
    RETURN 'skipped: DBT_RUNS_REFRESH in flight';
  END IF;
  CALL DLT_DB.OPS.SP_DBT_RUNS_REFRESH();
  RETURN 'swept';
END;
$$;

-- -----------------------------------------------------------------------------
-- Section 5: the thin view. Same name, same columns-plus-two (RETURN_VALUE
-- and REFRESHED_AT ride along harmlessly), same row filter the old view had:
-- SKIPPED evaluations and no-op drains are not build attempts. The filters
-- live HERE and not in the merge source, deliberately -- see Step 3's note.
-- COPY GRANTS preserves the dashboard role's SELECT.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW DLT_DB.OPS.V_DBT_RUNS
    COPY GRANTS
    COMMENT = 'Thin passthrough over DLT_DB.OPS.DBT_RUNS (materialised 2026-08; refresh logic in SP_DBT_RUNS_REFRESH). Filters out SKIPPED evaluations and no-op drains.'
AS
SELECT * FROM DLT_DB.OPS.DBT_RUNS
WHERE STATE NOT IN ('SKIPPED')
  AND COALESCE(RETURN_VALUE, '') NOT LIKE 'no-op%';

GRANT SELECT ON TABLE DLT_DB.OPS.DBT_RUNS TO ROLE DLT_DEV_ROLE;
GRANT SELECT ON VIEW DLT_DB.OPS.V_DBT_RUNS TO ROLE DLT_DEV_ROLE;

-- -----------------------------------------------------------------------------
-- Section 6: the tasks. Names avoid the DLT_TASK_ prefix (TASK_RUNS filter)
-- AND the DBT_BUILD_ prefix (this file's own spine filter): no
-- self-observation loop. Not managed by generate_tasks.py; suspend before
-- CREATE OR ALTER; the RESUMEs are not redundant.
--
-- On a FIRST apply the resumes mean the SHOW_INITIAL_ROWS streams fire the
-- refresh within about a minute, and the NULL watermark routes that fire
-- through the ACCOUNT_USAGE arm: applying this file IS the bootstrap.
-- -----------------------------------------------------------------------------

ALTER TASK IF EXISTS DLT_DB.OPS.DBT_RUNS_SWEEP SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DBT_RUNS_REFRESH SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DBT_OBS_COPY SUSPEND;

CREATE OR ALTER TASK DLT_DB.OPS.DBT_RUNS_REFRESH
  WAREHOUSE = DLT_WH
  -- Hourly, matching OBS_REFRESH (same warehouse): either twin at 60s keeps
  -- the warehouse from ever auto-suspending. Manual refresh covers in-between.
  -- At daily ingest cadence the streams fill around the builds, so this
  -- self-reduces to a few fires a day.
  USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 3600
  USER_TASK_TIMEOUT_MS = 600000
  COMMENT = 'Event-driven refresh of DBT_RUNS: fires when a build lands (DBT_BUILDS) or a harvest lands (DBT_QUERY_LOG, fills rollups). NOT managed by generate_tasks.py.'
  WHEN SYSTEM$STREAM_HAS_DATA('DLT_DB.OPS.STREAM_DBT_BUILDS')
    OR SYSTEM$STREAM_HAS_DATA('DLT_DB.OPS.STREAM_DBT_QUERY_LOG')
AS
  CALL DLT_DB.OPS.SP_DBT_RUNS_REFRESH();

CREATE OR ALTER TASK DLT_DB.OPS.DBT_RUNS_SWEEP
  WAREHOUSE = DLT_WH
  -- Twice daily at :30, a slot behind OBS_REFRESH_SWEEP at :15, both riding
  -- the warm period after the 12:30/22:30 NFL builds instead of waking the
  -- warehouse on their own schedule.
  SCHEDULE  = 'USING CRON 30 13,23 * * * UTC'
  COMMENT   = 'Backstop for FAILED builds (no stream event exists for them), twice daily at 13:30/23:30. NOT managed by generate_tasks.py.'
AS
  CALL DLT_DB.OPS.SP_DBT_RUNS_SWEEP();

-- Child before parent. IF EXISTS: DBT_OBS_COPY is created by ops/11.
ALTER TASK IF EXISTS DLT_DB.OPS.DBT_OBS_COPY RESUME;
ALTER TASK DLT_DB.OPS.DBT_RUNS_REFRESH RESUME;
ALTER TASK DLT_DB.OPS.DBT_RUNS_SWEEP RESUME;
