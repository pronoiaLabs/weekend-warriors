-- =============================================================================
-- ops/06_dbt_harvest.sql
-- =============================================================================
-- Purpose       : Shared dbt build observability: one row per build
--                 (DBT_BUILDS), one row per query a build ran (DBT_QUERY_LOG),
--                 and the query-profile capture (DBT_QUERY_OPERATOR_STATS),
--                 filled by SP_DBT_HARVEST from the per-sport harvest tasks.
--                 Plus the retention task for all of it.
-- Run as        : SYSADMIN for the grant slice, then DBT_RUNNER_ROLE (objects)
-- Prerequisites : sql/base/04_dbt_runner.sql (role + DBT_WH); the per-sport
--                 05_dbt_trigger.sql files add the DBT_HARVEST_<SPORT> child
--                 tasks that call the proc here.
-- Apply         : make setup-ops CONFIRM=1  (or snow sql -f directly)
--
-- WHY THIS EXISTS: SNOWFLAKE.ACCOUNT_USAGE lags (QUERY_HISTORY ~45 min,
-- DBT_PROJECT_EXECUTION_HISTORY up to 2 h), and the per-query profile behind
-- Snowsight's Query Profile tab is not in any view at all; it only comes from
-- GET_QUERY_OPERATOR_STATS, one completed query id at a time, within 14 days.
-- Harvesting right after each build gives the ops dashboard zero-latency
-- build + query-performance data and makes the profiles permanent.
--
-- THE CORRELATION KEY IS THE QUERY_TAG. dbt-pipelines stamps every query
-- with JSON: {"app":"dbt","sport":...,"env":...,"build_id":...,"node":...}
-- (profiles.yml query_tag + macros/query_tags.sql override; build_id passes
-- through EXECUTE DBT PROJECT ENV_VARS). Two spellings exist in the wild --
-- the literal base has no spaces, tojson output does -- so ALWAYS
-- TRY_PARSE_JSON the tag, never string-match it (measured both forms).
--
-- WHY A CALLER'S-RIGHTS PROC CAN DO ALL OF THIS (verified, WORKFLOW-5
-- Phase 0): the documented "stored procedures cannot run QUERY_HISTORY"
-- restriction is scoped to OWNER's-rights procs ("Requested information on
-- the current user is not accessible"); a caller's-rights proc runs
-- QUERY_HISTORY_BY_WAREHOUSE and GET_QUERY_OPERATOR_STATS fine, including
-- when a task invokes it. GET_QUERY_OPERATOR_STATS takes only a literal or
-- a bind (:var) -- a cursor record field or LATERAL join is a compile error
-- -- hence the assign-then-bind loop. ~660 ms per profiled query (measured
-- 10 in 6.6 s), so a typical build's 150-250 warehouse queries cost roughly
-- 1.5-2.5 min of XSMALL DBT_WH per harvest.
--
-- Privileges: OPERATE on DBT_WH (already granted in base/04) satisfies both
-- QUERY_HISTORY_BY_WAREHOUSE and GET_QUERY_OPERATOR_STATS. No ACCOUNT_USAGE
-- grant is needed anywhere in this file.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: grant slice (idempotent)
-- -----------------------------------------------------------------------------

USE ROLE SYSADMIN;

-- CREATE VIEW and CREATE STREAM are for 07_dbt_runs.sql, granted here so the
-- OPS write access for DBT_RUNNER_ROLE lives in one place.
GRANT USAGE, CREATE TABLE, CREATE PROCEDURE, CREATE VIEW, CREATE TASK, CREATE STREAM
  ON SCHEMA DLT_DB.OPS TO ROLE DBT_RUNNER_ROLE;

-- -----------------------------------------------------------------------------
-- Section 2: tables, owned by DBT_RUNNER_ROLE
-- -----------------------------------------------------------------------------

USE ROLE DBT_RUNNER_ROLE;

-- One row per triggered (or manual) prod build. Written by SP_DBT_BUILD in
-- the per-sport 05_dbt_trigger.sql files, right after EXECUTE DBT PROJECT
-- returns, so a row here means the build SUCCEEDED; failed builds exist only
-- in TASK_HISTORY / DBT_PROJECT_EXECUTION_HISTORY (the proc deliberately
-- lets the error propagate rather than swallowing it to write a row).
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.DBT_BUILDS (
  BUILD_ID       VARCHAR,        -- UUID minted by SP_DBT_BUILD; 'manual' runs lack a row here
  SPORT          VARCHAR,        -- 'nfl', 'wnba', ...
  ENVIRONMENT    VARCHAR,        -- env.yml environment the build ran as
  PROJECT_FQN    VARCHAR,        -- which project object built
  ARGS           VARCHAR,        -- 'run' / 'build' (the NFL run-vs-build split)
  DRAINED_LOADS  NUMBER,         -- how many dlt loads this build coalesced
  EXEC_QUERY_ID  VARCHAR,        -- query id of the EXECUTE DBT PROJECT statement
  STARTED_AT     TIMESTAMP_TZ,
  FINISHED_AT    TIMESTAMP_TZ
)
COMMENT = 'One row per successful event-driven dbt build. Correlate to queries via BUILD_ID in DBT_QUERY_LOG.';

-- One row per query the DBT_WH ran with a dbt query tag. Filled by
-- SP_DBT_HARVEST from INFORMATION_SCHEMA.QUERY_HISTORY_BY_WAREHOUSE
-- (7-day window, RESULT_LIMIT max 10000 applied BEFORE the filters --
-- fine while DBT_WH is dbt-only, which is the standing arrangement).
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.DBT_QUERY_LOG (
  QUERY_ID                    VARCHAR,
  BUILD_ID                    VARCHAR,  -- parsed from the tag; 'manual' for hand runs
  SPORT                       VARCHAR,  -- parsed from the tag
  ENVIRONMENT                 VARCHAR,  -- parsed from the tag
  NODE                        VARCHAR,  -- dbt unique_id, NULL on non-model statements
  QUERY_TYPE                  VARCHAR,
  EXECUTION_STATUS            VARCHAR,
  ERROR_CODE                  VARCHAR,
  ERROR_MESSAGE               VARCHAR,
  START_TIME                  TIMESTAMP_TZ,
  END_TIME                    TIMESTAMP_TZ,
  TOTAL_ELAPSED_TIME          NUMBER,   -- ms, like the source columns
  COMPILATION_TIME            NUMBER,
  EXECUTION_TIME              NUMBER,
  QUEUED_OVERLOAD_TIME        NUMBER,
  BYTES_SCANNED               NUMBER,
  ROWS_PRODUCED               NUMBER,
  ROWS_INSERTED               NUMBER,
  CREDITS_USED_CLOUD_SERVICES NUMBER(38, 9),
  WAREHOUSE_NAME              VARCHAR,
  QUERY_TAG                   VARCHAR,  -- raw tag, for anything the parse missed
  STATS_CAPTURED              BOOLEAN DEFAULT FALSE,
  HARVESTED_AT                TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'One row per dbt-tagged query on DBT_WH, harvested by SP_DBT_HARVEST after each build. STATS_CAPTURED marks the operator-stats pass.';

-- The Query Profile, persisted: one row per operator per profiled query.
-- Shape matches GET_QUERY_OPERATOR_STATS output exactly, plus CAPTURED_AT.
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS (
  QUERY_ID                 VARCHAR,
  STEP_ID                  NUMBER,
  OPERATOR_ID              NUMBER,
  PARENT_OPERATORS         ARRAY,
  OPERATOR_TYPE            VARCHAR,
  OPERATOR_STATISTICS      VARIANT,
  EXECUTION_TIME_BREAKDOWN VARIANT,
  OPERATOR_ATTRIBUTES      VARIANT,
  CAPTURED_AT              TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'GET_QUERY_OPERATOR_STATS output per harvested query: the Snowsight Query Profile, made permanent and joinable.';

GRANT SELECT ON TABLE DLT_DB.OPS.DBT_BUILDS TO ROLE DLT_DEV_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_QUERY_LOG TO ROLE DLT_DEV_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS TO ROLE DLT_DEV_ROLE;

-- -----------------------------------------------------------------------------
-- Section 3: the harvest procedure
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_DBT_HARVEST()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Enumerate new dbt-tagged DBT_WH queries into DBT_QUERY_LOG, then capture operator stats per warehouse-executing query. Caller''s rights is REQUIRED: owner''s-rights procs cannot run QUERY_HISTORY (verified).'
EXECUTE AS CALLER
AS
$$
DECLARE
  n_new INTEGER;
  n_profiled INTEGER DEFAULT 0;
  n_skipped INTEGER DEFAULT 0;
  n_failed_chunks INTEGER DEFAULT 0;
  in_flight INTEGER DEFAULT 0;
  qid VARCHAR;
  -- Only statement types that carry a real query plan get a profile pass.
  -- An allowlist, and NOT an execution-time floor: measured live, even USE
  -- and ALTER SESSION report 8-14 ms of "execution time", so a nonzero-time
  -- filter admits thousands of metadata no-ops per day (5.2k USE, 2.6k
  -- ALTER_SESSION, 1.3k SHOW in the first day) that would each waste a
  -- ~1 s profile call to return zero operator rows. STATS_CAPTURED flips
  -- even when a profile comes back empty, so nothing is retried forever.
  --
  -- BOUNDED PER RUN, heaviest first. GET_QUERY_OPERATOR_STATS averaged
  -- ~660 ms in spiking but was measured live taking 50 s to minutes on some
  -- queries, so an unbounded loop over a backlog can outlive the task
  -- timeout. 200 per run keeps a harvest inside a few minutes; the
  -- ORDER BY means the expensive queries (the ones worth profiling) land
  -- first and the tail drains over subsequent builds.
  c_pending CURSOR FOR
    SELECT QUERY_ID FROM DLT_DB.OPS.DBT_QUERY_LOG
    WHERE NOT STATS_CAPTURED
      AND QUERY_TYPE IN ('SELECT', 'INSERT', 'MERGE', 'UPDATE', 'DELETE',
                         'CREATE_TABLE_AS_SELECT', 'COPY', 'UNLOAD')
    ORDER BY TOTAL_ELAPSED_TIME DESC
    LIMIT 200;
BEGIN
  -- 1. Enumerate. High-water mark on END_TIME with a 60s overlap window; the
  -- MERGE makes the overlap (and a concurrent harvest from the other sport's
  -- task) idempotent. In-flight queries have no END_TIME yet and are picked
  -- up by the next harvest.
  MERGE INTO DLT_DB.OPS.DBT_QUERY_LOG dst
  USING (
    SELECT
      q.QUERY_ID,
      COALESCE(TRY_PARSE_JSON(q.QUERY_TAG):build_id::VARCHAR, 'manual') AS BUILD_ID,
      TRY_PARSE_JSON(q.QUERY_TAG):sport::VARCHAR AS SPORT,
      TRY_PARSE_JSON(q.QUERY_TAG):env::VARCHAR AS ENVIRONMENT,
      TRY_PARSE_JSON(q.QUERY_TAG):node::VARCHAR AS NODE,
      q.QUERY_TYPE, q.EXECUTION_STATUS, q.ERROR_CODE, q.ERROR_MESSAGE,
      q.START_TIME, q.END_TIME,
      q.TOTAL_ELAPSED_TIME, q.COMPILATION_TIME, q.EXECUTION_TIME,
      q.QUEUED_OVERLOAD_TIME, q.BYTES_SCANNED, q.ROWS_PRODUCED,
      q.ROWS_INSERTED, q.CREDITS_USED_CLOUD_SERVICES,
      q.WAREHOUSE_NAME, q.QUERY_TAG
    FROM TABLE(DLT_DB.INFORMATION_SCHEMA.QUERY_HISTORY_BY_WAREHOUSE(
           WAREHOUSE_NAME => 'DBT_WH', RESULT_LIMIT => 10000)) q
    WHERE TRY_PARSE_JSON(q.QUERY_TAG):app::VARCHAR = 'dbt'
      AND q.END_TIME IS NOT NULL
      AND q.EXECUTION_STATUS NOT IN ('RUNNING', 'QUEUED', 'BLOCKED')
      AND q.END_TIME >= COALESCE(
            (SELECT DATEADD('second', -60, MAX(END_TIME)) FROM DLT_DB.OPS.DBT_QUERY_LOG),
            DATEADD('hour', -24, CURRENT_TIMESTAMP()))
  ) src
  ON dst.QUERY_ID = src.QUERY_ID
  WHEN NOT MATCHED THEN INSERT (
    QUERY_ID, BUILD_ID, SPORT, ENVIRONMENT, NODE, QUERY_TYPE,
    EXECUTION_STATUS, ERROR_CODE, ERROR_MESSAGE, START_TIME, END_TIME,
    TOTAL_ELAPSED_TIME, COMPILATION_TIME, EXECUTION_TIME,
    QUEUED_OVERLOAD_TIME, BYTES_SCANNED, ROWS_PRODUCED, ROWS_INSERTED,
    CREDITS_USED_CLOUD_SERVICES, WAREHOUSE_NAME, QUERY_TAG
  ) VALUES (
    src.QUERY_ID, src.BUILD_ID, src.SPORT, src.ENVIRONMENT, src.NODE,
    src.QUERY_TYPE, src.EXECUTION_STATUS, src.ERROR_CODE, src.ERROR_MESSAGE,
    src.START_TIME, src.END_TIME, src.TOTAL_ELAPSED_TIME,
    src.COMPILATION_TIME, src.EXECUTION_TIME, src.QUEUED_OVERLOAD_TIME,
    src.BYTES_SCANNED, src.ROWS_PRODUCED, src.ROWS_INSERTED,
    src.CREDITS_USED_CLOUD_SERVICES, src.WAREHOUSE_NAME, src.QUERY_TAG
  );
  n_new := SQLROWCOUNT;

  -- 2. Profile, 8 at a time. Assign-then-bind: GET_QUERY_OPERATOR_STATS
  -- rejects a cursor record field and a LATERAL join; only a literal or a
  -- :bind compiles.
  --
  -- ASYNC fan-out: serial calls were the bottleneck (0.5 s to 50 s+ each,
  -- measured live; two harvests timed out at 30 min on the first backlog).
  -- Each INSERT runs as an asynchronous child job; AWAIT ALL closes the
  -- chunk. Chunks of 8 match a default MAX_CONCURRENCY_LEVEL warehouse, and
  -- the per-chunk EXCEPTION handler keeps one bad query id (aged past the
  -- 14-day window, say) from killing the run: AWAIT is fail-fast, and child
  -- jobs still running when the proc returns would be auto-cancelled.
  --
  -- CLAIM FIRST: two harvests can run concurrently (each sport's child, and
  -- the sports build simultaneously on Tuesdays). Flipping STATS_CAPTURED
  -- before profiling makes each row single-winner (statements autocommit
  -- here, so the loser's UPDATE reports 0 rows and it moves on) instead of
  -- both sessions paying the profile call for the same query. A claimed row
  -- whose child job failed keeps its flag and simply has no operator rows:
  -- acceptable, and visible as a NULL join from the dashboard.
  FOR rec IN c_pending DO
    qid := rec.QUERY_ID;
    UPDATE DLT_DB.OPS.DBT_QUERY_LOG SET STATS_CAPTURED = TRUE
      WHERE QUERY_ID = :qid AND NOT STATS_CAPTURED;
    IF (SQLROWCOUNT = 0) THEN
      n_skipped := n_skipped + 1;
      CONTINUE;
    END IF;
    ASYNC (
      INSERT INTO DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS (
        QUERY_ID, STEP_ID, OPERATOR_ID, PARENT_OPERATORS, OPERATOR_TYPE,
        OPERATOR_STATISTICS, EXECUTION_TIME_BREAKDOWN, OPERATOR_ATTRIBUTES
      )
        SELECT QUERY_ID, STEP_ID, OPERATOR_ID, PARENT_OPERATORS, OPERATOR_TYPE,
               OPERATOR_STATISTICS, EXECUTION_TIME_BREAKDOWN, OPERATOR_ATTRIBUTES
        FROM TABLE(GET_QUERY_OPERATOR_STATS(:qid))
    );
    in_flight := in_flight + 1;
    n_profiled := n_profiled + 1;
    IF (in_flight >= 8) THEN
      BEGIN
        AWAIT ALL;
      EXCEPTION
        WHEN OTHER THEN
          n_failed_chunks := n_failed_chunks + 1;
      END;
      in_flight := 0;
    END IF;
  END FOR;

  -- Never RETURN with children in flight: they would be auto-cancelled.
  BEGIN
    AWAIT ALL;
  EXCEPTION
    WHEN OTHER THEN
      n_failed_chunks := n_failed_chunks + 1;
  END;

  RETURN 'logged ' || n_new || ' queries, profiled ' || n_profiled ||
         ' (' || n_skipped || ' claimed elsewhere, ' || n_failed_chunks || ' chunk errors)';
END;
$$;

-- -----------------------------------------------------------------------------
-- Section 4: retention
-- -----------------------------------------------------------------------------
-- Same shape as 05_retention.sql (hand-written task, CREATE OR ALTER +
-- explicit RESUME, name must NOT start with DLT_TASK_). Runs 15 min after
-- the event-table sweep on the same weekly cadence. The body is a proc, not
-- an inline scripting block, so the CLI statement splitter never sees the
-- inner semicolons.
--
-- Numbers: operator stats are the bulky ones (~5-15k VARIANT rows per build,
-- ~8 builds/day) so they and the query log keep 90 days -- a full season of
-- performance history. DBT_BUILDS and the per-sport DBT_TRIGGER_LOADS audit
-- tables are a few rows per day and keep 365, matching ACCOUNT_USAGE reach.
-- ADDING A SPORT: add its DBT_TRIGGER_LOADS DELETE here (the scaffold's
-- next-steps text says so).

CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_DBT_OBS_RETENTION()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Weekly sweep of the dbt observability tables. 90d for query log + operator stats, 365d for build and trigger audit rows.'
EXECUTE AS CALLER
AS
$$
BEGIN
  DELETE FROM DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS
    WHERE CAPTURED_AT < DATEADD('day', -90, CURRENT_TIMESTAMP());
  DELETE FROM DLT_DB.OPS.DBT_QUERY_LOG
    WHERE HARVESTED_AT < DATEADD('day', -90, CURRENT_TIMESTAMP());
  DELETE FROM DLT_DB.OPS.DBT_BUILDS
    WHERE FINISHED_AT < DATEADD('day', -365, CURRENT_TIMESTAMP());
  DELETE FROM NFL_PROD_DB.OPS.DBT_TRIGGER_LOADS
    WHERE DRAINED_AT < DATEADD('day', -365, CURRENT_TIMESTAMP());
  DELETE FROM WNBA_PROD_DB.OPS.DBT_TRIGGER_LOADS
    WHERE DRAINED_AT < DATEADD('day', -365, CURRENT_TIMESTAMP());
  DELETE FROM NCAAF_PROD_DB.OPS.DBT_TRIGGER_LOADS
    WHERE DRAINED_AT < DATEADD('day', -365, CURRENT_TIMESTAMP());
  -- The materialised run table and its refresh audit (07_dbt_runs.sql). LAST
  -- in the body deliberately: on a fresh account this proc can exist before
  -- 07 has been applied, and the earlier DELETEs autocommit individually, so
  -- a missing-table failure here loses nothing that already ran.
  DELETE FROM DLT_DB.OPS.DBT_RUNS
    WHERE STARTED_AT < DATEADD('day', -365, CURRENT_TIMESTAMP());
  DELETE FROM DLT_DB.OPS.DBT_RUNS_REFRESH_LOG
    WHERE FIRED_AT < DATEADD('day', -365, CURRENT_TIMESTAMP());
  RETURN 'swept';
END;
$$;

ALTER TASK IF EXISTS DLT_DB.OPS.DBT_OBS_RETENTION SUSPEND;

CREATE OR ALTER TASK DLT_DB.OPS.DBT_OBS_RETENTION
  WAREHOUSE = DBT_WH
  SCHEDULE = 'USING CRON 45 4 * * 0 UTC'
  COMMENT = 'Weekly retention sweep of the dbt observability tables. Hand-written; NOT managed by generate_tasks.py.'
AS
  CALL DLT_DB.OPS.SP_DBT_OBS_RETENTION();

-- Not redundant: CREATE OR ALTER TASK leaves the task suspended.
ALTER TASK DLT_DB.OPS.DBT_OBS_RETENTION RESUME;
