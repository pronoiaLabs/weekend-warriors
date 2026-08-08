-- =============================================================================
-- ops/04_run_summary.sql
-- Purpose : One row per scheduled pipeline run: task outcome, timings, log rollup
--           and resource samples. Source-agnostic; per-sport row counts join on in
--           sql/sources/<name>/04_run_summary.sql.
-- Run as  : DLT_LOADER_ROLE, which owns it.
-- Prerequisites : ops/02_log_lines.sql, ops/03_metrics.sql.
-- Apply   : make setup-ops CONFIRM=1
--
-- TWO TASK-HISTORY SOURCES, UNIONED, BECAUSE NEITHER IS SUFFICIENT ALONE
--   INFORMATION_SCHEMA.TASK_HISTORY is a table function: 7 days, no lag.
--   ACCOUNT_USAGE.TASK_HISTORY is a view: 365 days, up to 45 minutes of lag.
--
--   The lag is not academic. Measured on 2026-08-08, ACCOUNT_USAGE was 47 minutes
--   behind and did not contain a production run that had already finished. An ops
--   view is read immediately after something fails, which is exactly when a
--   three-quarter-hour blind spot is worthless. So the live function wins for recent
--   runs and ACCOUNT_USAGE supplies everything older.
--
--   A view CAN wrap an INFORMATION_SCHEMA table function. That was an open question
--   in the design and the answer is yes, verified by building one.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

CREATE OR REPLACE VIEW DLT_DB.OPS.V_TASK_RUNS
    COMMENT = 'One row per scheduled dlt Task run: outcome, duration, log and resource rollup.'
AS
WITH

-- ---------------------------------------------------------------------------
-- 1. Recent task history, no lag.
--
-- RESULT_LIMIT IS NOT OPTIONAL AND ITS DEFAULT IS A TRAP.
--   TASK_HISTORY returns 100 rows unless told otherwise. Seventeen Tasks over seven
--   days is well past that, so the default would silently truncate the view to the
--   most recent handful and every older run would simply vanish. There would be no
--   error and no clue. 10000 is the maximum the function accepts.
-- ---------------------------------------------------------------------------
th_live AS (
    SELECT
        1 AS SOURCE_RANK,
        'live' AS HISTORY_SOURCE,
        NAME, QUERY_ID, STATE, SCHEDULED_TIME,
        QUERY_START_TIME, COMPLETED_TIME, ERROR_MESSAGE
    FROM TABLE(DLT_DB.INFORMATION_SCHEMA.TASK_HISTORY(RESULT_LIMIT => 10000))
    WHERE NAME ILIKE 'DLT\_TASK\_%' ESCAPE '\\'
      -- Drops future SCHEDULED rows, which carry no QUERY_ID and are not runs.
      AND QUERY_START_TIME IS NOT NULL
),

-- ---------------------------------------------------------------------------
-- 2. Long-range task history, lagged.
--
-- Filtered to DLT_DB so a Task created elsewhere in the account can never appear
-- here, and to the dlt_task_ prefix so the retention Task in ops/05 does not show up
-- as a phantom pipeline. That prefix rule is why ops/05 is deliberately NOT named
-- dlt_task_retention.
-- ---------------------------------------------------------------------------
th_hist AS (
    SELECT
        2 AS SOURCE_RANK,
        'account_usage' AS HISTORY_SOURCE,
        NAME, QUERY_ID, STATE, SCHEDULED_TIME,
        QUERY_START_TIME, COMPLETED_TIME, ERROR_MESSAGE
    FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
    WHERE DATABASE_NAME = 'DLT_DB'
      AND NAME ILIKE 'DLT\_TASK\_%' ESCAPE '\\'
      AND QUERY_START_TIME IS NOT NULL
),

-- ---------------------------------------------------------------------------
-- 3. One row per run, live winning any overlap.
--
-- The two sources overlap for the last seven days and describe the same run with the
-- same QUERY_ID, so this is a deduplicate rather than a merge. SOURCE_RANK decides,
-- and HISTORY_SOURCE is kept as a column so a surprising row can be traced back to
-- which source produced it.
-- ---------------------------------------------------------------------------
-- QUALIFY MUST SIT IN ITS OWN SELECT, NOT ON THE UNION.
--   Written as `SELECT ... UNION ALL SELECT ... QUALIFY ...` the clause binds to the
--   LAST branch only and the deduplicate silently does not happen. It does not error;
--   it returns every run twice, once per source, and a count of runs quietly doubles.
--   Caught by seeing each run listed as both 'live' and 'account_usage'.
th_all AS (
    SELECT * FROM th_live
    UNION ALL
    SELECT * FROM th_hist
),
th AS (
    SELECT * FROM th_all
    QUALIFY ROW_NUMBER() OVER (PARTITION BY QUERY_ID ORDER BY SOURCE_RANK) = 1
),

-- ---------------------------------------------------------------------------
-- 4. When telemetry collection actually began.
--
-- WITHOUT THIS, EVERY RUN OLDER THAN THE EVENT TABLE LOOKS LIKE A CRASHED CONTAINER.
--   ACCOUNT_USAGE reaches back 365 days. DLT_DB.OPS.DLT_EVENTS was created on
--   2026-08-08 and everything before it went to SNOWFLAKE.TELEMETRY.EVENTS. A plain
--   `no telemetry` test would therefore report CONTAINER_NEVER_STARTED for months of
--   perfectly healthy runs.
--
--   Read from the data rather than hardcoded, so it stays correct if the table is
--   ever recreated, and so it moves forward on its own as ops/05 trims old rows.
-- ---------------------------------------------------------------------------
telemetry_window AS (
    SELECT MIN(TIMESTAMP) AS TELEMETRY_FROM FROM DLT_DB.OPS.DLT_EVENTS
),

-- ---------------------------------------------------------------------------
-- 5. Log rollup, one row per run.
--
-- PIPELINE_FROM_LOG is MAX() because only a handful of lines per run carry the name
-- at all. MAX promotes it from those lines to the whole run. It is a cross-check
-- against the task name, not the join key; QUERY_ID is the key.
-- ---------------------------------------------------------------------------
logs AS (
    SELECT
        QUERY_ID,
        MIN(EVENT_TS)                                  AS FIRST_LOG_AT,
        MAX(EVENT_TS)                                  AS LAST_LOG_AT,
        COUNT(*)                                       AS LOG_LINES,
        COUNT_IF(SEVERITY = 'ERROR')                   AS ERROR_LINES,
        COUNT_IF(SEVERITY IN ('WARNING', 'WARN'))      AS WARNING_LINES,
        COUNT_IF(LOG_FORMAT = 'continuation')          AS UNPARSED_LINES,
        MAX(PIPELINE)                                  AS PIPELINE_FROM_LOG,
        MAX(SERVICE_NAME)                              AS SERVICE_NAME
    FROM DLT_DB.OPS.V_LOG_LINES
    GROUP BY QUERY_ID
),

-- ---------------------------------------------------------------------------
-- 6. Resource rollup, one row per run.
--
-- EVERY AGGREGATE HERE CARRIES ITS SAMPLE COUNT, AND THAT IS THE POINT.
--   A 92 second run yields one container.cpu.usage sample and two for memory, against
--   a ~30 second scrape. So CPU_CORES_MAX is one reading that happens to be the
--   largest of one, and naming it PEAK would be a lie the column could not support.
--   CPU_SAMPLES and MEM_SAMPLES sit beside them so a consumer can see the weight of
--   evidence and decide whether to trust it.
--
--   The limits are sampled on every scrape and are effectively constant, so they are
--   trustworthy and are what make a utilisation percentage possible at all.
--   RESTARTS is a count rather than a gauge and needs no such caveat.
-- ---------------------------------------------------------------------------
metrics AS (
    SELECT
        QUERY_ID,
        MAX(COMPUTE_POOL)                                                   AS COMPUTE_POOL,
        MAX(NODE_INSTANCE_FAMILY)                                           AS NODE_INSTANCE_FAMILY,
        COUNT(*)                                                            AS METRIC_SAMPLES,

        MAX(IFF(METRIC_NAME = 'container.cpu.usage',        METRIC_VALUE, NULL)) AS CPU_CORES_MAX,
        COUNT_IF(METRIC_NAME = 'container.cpu.usage')                            AS CPU_SAMPLES,
        MAX(IFF(METRIC_NAME = 'container.cpu.limit',        METRIC_VALUE, NULL)) AS CPU_CORES_LIMIT,
        MAX(IFF(METRIC_NAME = 'container.cpu.requested',    METRIC_VALUE, NULL)) AS CPU_CORES_REQUESTED,

        MAX(IFF(METRIC_NAME = 'container.memory.usage',     METRIC_VALUE, NULL)) AS MEM_BYTES_MAX,
        COUNT_IF(METRIC_NAME = 'container.memory.usage')                         AS MEM_SAMPLES,
        MAX(IFF(METRIC_NAME = 'container.memory.limit',     METRIC_VALUE, NULL)) AS MEM_BYTES_LIMIT,
        MAX(IFF(METRIC_NAME = 'container.memory.requested', METRIC_VALUE, NULL)) AS MEM_BYTES_REQUESTED,

        MAX(IFF(METRIC_NAME = 'container.restarts',         METRIC_VALUE, NULL)) AS RESTARTS,
        SUM(IFF(METRIC_NAME = 'network.egress.received.bytes',    METRIC_VALUE, 0)) AS NET_RX_BYTES,
        SUM(IFF(METRIC_NAME = 'network.egress.transmitted.bytes', METRIC_VALUE, 0)) AS NET_TX_BYTES
    FROM DLT_DB.OPS.V_METRICS
    GROUP BY QUERY_ID
)

SELECT
    -- ---------------------------------------------------------------------
    -- Identity. PIPELINE is derived from the Task name rather than from the logs,
    -- because the Task name exists for every run including ones whose container
    -- never produced a line.
    -- ---------------------------------------------------------------------
    LOWER(REGEXP_SUBSTR(th.NAME, '^DLT_TASK_(.*)$', 1, 1, 'e', 1)) AS PIPELINE,
    th.NAME                                                        AS TASK_NAME,
    th.QUERY_ID,
    logs.SERVICE_NAME,
    m.COMPUTE_POOL,
    m.NODE_INSTANCE_FAMILY,
    th.HISTORY_SOURCE,

    -- ---------------------------------------------------------------------
    -- Outcome.
    --
    -- EXIT_STATUS is parsed out of the message because THERE IS NO NUMERIC EXIT CODE
    -- ANYWHERE: not in TASK_HISTORY, not in SHOW SERVICES, not in the event table.
    -- The documented container.state.last.finished.exitcode metric does not exist in
    -- practice. All that survives is the word in
    -- `Job JOB_... failed to complete. Exited with status: FAILED.`
    -- ---------------------------------------------------------------------
    th.STATE,
    th.ERROR_MESSAGE                                               AS TASK_ERROR_MESSAGE,
    REGEXP_SUBSTR(th.ERROR_MESSAGE, 'Exited with status: ([A-Z]+)', 1, 1, 'e', 1)
                                                                   AS EXIT_STATUS,

    -- ---------------------------------------------------------------------
    -- Timings, and why there are three of them.
    --
    -- DURATION_S is the truth about how long the Task took. CONTAINER_SPAN_S is how
    -- long the container was talking. The gap between them is compute pool
    -- scheduling plus image pull, and it is large: 68s against 26s on a measured run,
    -- so telemetry alone understates a run by more than half.
    --
    -- Splitting them is what distinguishes a slow pipeline from a slow pool, which is
    -- the first question anyone asks about a run that took longer than usual.
    -- ---------------------------------------------------------------------
    th.SCHEDULED_TIME,
    th.QUERY_START_TIME                                            AS RUN_STARTED_AT,
    th.COMPLETED_TIME                                              AS RUN_ENDED_AT,
    DATEDIFF('second', th.QUERY_START_TIME, th.COMPLETED_TIME)     AS DURATION_S,
    DATEDIFF('second', logs.FIRST_LOG_AT, logs.LAST_LOG_AT)        AS CONTAINER_SPAN_S,
    DATEDIFF('second', th.QUERY_START_TIME, th.COMPLETED_TIME)
      - DATEDIFF('second', logs.FIRST_LOG_AT, logs.LAST_LOG_AT)    AS STARTUP_OVERHEAD_S,

    -- ---------------------------------------------------------------------
    -- Log rollup. UNPARSED_LINES is the parser's own coverage report: a run where it
    -- climbs means a log format changed underneath ops/02, which is otherwise
    -- invisible because unparsed lines still return their raw text.
    -- ---------------------------------------------------------------------
    logs.LOG_LINES,
    logs.ERROR_LINES,
    logs.WARNING_LINES,
    logs.UNPARSED_LINES,
    logs.PIPELINE_FROM_LOG,

    -- ---------------------------------------------------------------------
    -- Resources. Read CPU_SAMPLES and MEM_SAMPLES before believing the maxima.
    -- ---------------------------------------------------------------------
    m.METRIC_SAMPLES,
    m.CPU_CORES_MAX,
    m.CPU_SAMPLES,
    m.CPU_CORES_LIMIT,
    m.CPU_CORES_REQUESTED,
    m.MEM_BYTES_MAX,
    m.MEM_SAMPLES,
    m.MEM_BYTES_LIMIT,
    m.MEM_BYTES_REQUESTED,
    m.RESTARTS,
    m.NET_RX_BYTES,
    m.NET_TX_BYTES,

    -- ---------------------------------------------------------------------
    -- Two different kinds of nothing, which must not be confused.
    --
    -- TELEMETRY_AVAILABLE is false for runs that predate the event table. Their logs
    -- exist, in SNOWFLAKE.TELEMETRY.EVENTS, and are simply not reachable from here.
    -- That is a boundary, not a fault.
    --
    -- CONTAINER_NEVER_STARTED is only meaningful once telemetry was being collected,
    -- and then it is a real signal: the Task ran, the container produced nothing, so
    -- the failure was in the Task or the compute pool rather than in the pipeline.
    -- Live data holds one and two second failures of exactly this shape.
    -- ---------------------------------------------------------------------
    -- THE CONVERT_TIMEZONE IS LOAD BEARING AND ITS ABSENCE FAILS QUIETLY.
    --   The event table's TIMESTAMP is TIMESTAMP_NTZ holding UTC. TASK_HISTORY's
    --   QUERY_START_TIME is TIMESTAMP_LTZ. Compared directly, Snowflake reads the NTZ
    --   value in the session timezone, so a boundary of 16:28 UTC is treated as 16:28
    --   local and lands seven hours in the future. Every run then reports
    --   TELEMETRY_AVAILABLE = FALSE, including ones sitting on 416 log lines, and
    --   nothing errors.
    (CONVERT_TIMEZONE('UTC', th.QUERY_START_TIME)::TIMESTAMP_NTZ >= w.TELEMETRY_FROM)
                                                                   AS TELEMETRY_AVAILABLE,
    (CONVERT_TIMEZONE('UTC', th.QUERY_START_TIME)::TIMESTAMP_NTZ >= w.TELEMETRY_FROM
        AND logs.QUERY_ID IS NULL)                                 AS CONTAINER_NEVER_STARTED

FROM th
CROSS JOIN telemetry_window w
LEFT JOIN logs    ON logs.QUERY_ID = th.QUERY_ID
LEFT JOIN metrics m ON m.QUERY_ID  = th.QUERY_ID;

GRANT SELECT ON VIEW DLT_DB.OPS.V_TASK_RUNS TO ROLE DLT_DEV_ROLE;
