-- =============================================================================
-- sources/ncaaf/04_run_summary.sql
-- Purpose : NCAAF run summary. DLT_DB.OPS.V_TASK_RUNS plus the row counts and
--           status dlt recorded for itself in NCAAF_PROD_DB.OPS._DLT_RUNS.
-- Run as  : DLT_LOADER_ROLE.
-- Prerequisites : ops/04_run_summary.sql, and at least one completed NCAAF run so
--                 that _DLT_RUNS exists (dlt creates it, no DDL declares it).
-- Apply   : make setup-source SOURCE=ncaaf CONFIRM=1
--
-- A copy of sources/nfl/04_run_summary.sql with the database and pipeline prefix
-- swapped, which is the intended extension model: _DLT_RUNS is per destination
-- database by design, so run history sits beside the data it describes, adding a
-- sport is a new file here rather than a widening UNION in DLT_DB, and the
-- control plane never has to learn the name of every league.
--
-- THE JOIN IS A TIME WINDOW, WHICH IS THE WEAKEST LINK IN THIS LAYER
--   _DLT_RUNS carries no query id and no service name, so a row is matched by
--   pipeline name plus "finished inside this Task's window". Ambiguous only if
--   the same pipeline runs twice concurrently, which the schedule never does.
--   The recorded fix (stamping SNOWFLAKE_SERVICE_NAME in observability.py) is in
--   the NFL file's header and BACKLOG.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

CREATE OR REPLACE VIEW NCAAF_PROD_DB.OPS.V_PIPELINE_RUNS
    COMMENT = 'One row per NCAAF pipeline run: task outcome, duration, resources, rows loaded, error.'
AS
WITH dlt_runs AS (
    -- Flatten row_counts to a single total per run. outer => TRUE keeps failed
    -- runs (ROW_COUNTS NULL); _dlt_pipeline_state is dlt bookkeeping, not data,
    -- and counting it inflates every run by one row.
    SELECT
        r._DLT_ID,
        r.PIPELINE,
        r.STATUS,
        r.LOAD_ID,
        r.FINISHED_AT,
        r.ERROR,
        r.RESOURCES,
        ANY_VALUE(r.ROW_COUNTS)                                    AS ROW_COUNTS,
        SUM(CASE WHEN f.key = '_dlt_pipeline_state' THEN 0
                 ELSE f.value::number END)                         AS ROWS_LOADED
    FROM NCAAF_PROD_DB.OPS._DLT_RUNS r,
         LATERAL FLATTEN(input => r.ROW_COUNTS, outer => TRUE) f
    GROUP BY r._DLT_ID, r.PIPELINE, r.STATUS, r.LOAD_ID,
             r.FINISHED_AT, r.ERROR, r.RESOURCES
),

-- When _DLT_RUNS started collecting, which is NOT when telemetry started. Guarding
-- DLT_RECORD_MISSING on the wrong boundary silently suppresses every real gap; see
-- the NFL file for the full account. Computed from the data so it stays right if
-- the table is recreated.
dlt_window AS (
    SELECT MIN(FINISHED_AT) AS DLT_RUNS_FROM FROM NCAAF_PROD_DB.OPS._DLT_RUNS
)
SELECT
    t.PIPELINE,
    t.TASK_NAME,
    t.QUERY_ID,
    t.SERVICE_NAME,
    t.COMPUTE_POOL,

    t.RUN_STARTED_AT,
    t.RUN_ENDED_AT,
    t.DURATION_S,
    t.CONTAINER_SPAN_S,
    t.STARTUP_OVERHEAD_S,

    -- Two independent verdicts, kept separate on purpose: what Snowflake saw and
    -- what the pipeline recorded about itself. The interesting case is when they
    -- disagree.
    t.STATE                                                        AS TASK_STATE,
    d.STATUS                                                       AS DLT_STATUS,
    (t.STATE = 'SUCCEEDED' AND d.STATUS IS DISTINCT FROM 'ok')     AS OUTCOME_DISAGREES,

    -- _DLT_RUNS under-reports failures (record_run runs inside run_pipeline, so
    -- early deaths are never recorded). A NULL here inside the _DLT_RUNS window is
    -- a finding, not an absence; V_TASK_RUNS is the spine for exactly this reason.
    (d._DLT_ID IS NULL AND t.RUN_STARTED_AT >= w.DLT_RUNS_FROM)    AS DLT_RECORD_MISSING,

    d.ROWS_LOADED,
    d.ROW_COUNTS,                       -- per-table counts, keyed by table name
    d.LOAD_ID,
    d.RESOURCES,                        -- non-NULL means a partial run (--resource)

    -- dlt's exception string is the useful error; the Task message only ever says
    -- "Exited with status: FAILED", so it is the fallback.
    COALESCE(d.ERROR, t.TASK_ERROR_MESSAGE)                        AS ERROR_TEXT,
    t.EXIT_STATUS,

    t.LOG_LINES,
    t.ERROR_LINES,
    t.WARNING_LINES,
    t.UNPARSED_LINES,

    -- Read the sample counts before trusting the maxima: 1 to 4 readings per run.
    t.METRIC_SAMPLES,
    t.CPU_CORES_MAX,
    t.CPU_SAMPLES,
    t.CPU_CORES_LIMIT,
    t.MEM_BYTES_MAX,
    t.MEM_SAMPLES,
    t.MEM_BYTES_REQUESTED,
    t.RESTARTS,

    t.TELEMETRY_AVAILABLE,
    t.CONTAINER_NEVER_STARTED
FROM DLT_DB.OPS.V_TASK_RUNS t
CROSS JOIN dlt_window w
LEFT JOIN dlt_runs d
       ON d.PIPELINE = t.PIPELINE
      AND d.FINISHED_AT BETWEEN t.RUN_STARTED_AT AND t.RUN_ENDED_AT
WHERE t.PIPELINE LIKE 'ncaaf\_%' ESCAPE '\\';

GRANT SELECT ON VIEW NCAAF_PROD_DB.OPS.V_PIPELINE_RUNS TO ROLE DLT_DEV_ROLE;
