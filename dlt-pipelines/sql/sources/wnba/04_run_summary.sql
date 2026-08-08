-- =============================================================================
-- sources/wnba/04_run_summary.sql
-- Purpose : WNBA run summary. DLT_DB.OPS.V_TASK_RUNS plus the row counts and status
--           dlt recorded for itself in WNBA_PROD_DB.OPS._DLT_RUNS.
-- Run as  : DLT_LOADER_ROLE.
-- Prerequisites : ops/04_run_summary.sql, and at least one completed WNBA run so
--                 that _DLT_RUNS exists (dlt creates it, no DDL declares it).
-- Apply   : make setup-source SOURCE=wnba CONFIRM=1
--
-- WHY THIS LIVES BESIDE THE DATA AND NOT IN THE CONTROL PLANE
--   _DLT_RUNS is per destination database by design, so run history sits beside the
--   data it describes. Keeping the join here means adding a third sport is a new file
--   under sql/sources/<name>/ rather than an edit to a widening UNION in DLT_DB, and
--   nothing in the control plane has to learn the name of every league.
--
--   DLT_DB.OPS.V_TASK_RUNS stays source-agnostic: it knows about Tasks, containers
--   and metrics, and nothing about football.
--
-- THE JOIN IS A TIME WINDOW, WHICH IS THE WEAKEST LINK IN THIS LAYER
--   _DLT_RUNS carries no query id, no service name, nothing that identifies the run
--   it belongs to. So a row is matched by pipeline name plus "finished inside this
--   Task's window". Verified against all live rows: no fan-out, 35 of 42 NFL Task
--   runs matched.
--
--   The 35-of-42 figure is the NFL fleet, where it was measured. This file is a
--   deliberate copy of sources/nfl/04_run_summary.sql differing only in database
--   and prefix, which is what lets a sport be added or dropped as a single file.
--
--   It would become ambiguous if the same pipeline ever ran twice concurrently. The
--   fix is one line in pipelines/common/observability.py, stamping
--   os.environ['SNOWFLAKE_SERVICE_NAME'] onto the record, after which this becomes an
--   equality join on SERVICE_NAME. Not done, and worth doing before any pipeline is
--   scheduled more than once an hour.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

CREATE OR REPLACE VIEW WNBA_PROD_DB.OPS.V_PIPELINE_RUNS
    COMMENT = 'One row per WNBA pipeline run: task outcome, duration, resources, rows loaded, error.'
AS
WITH dlt_runs AS (
    -- ---------------------------------------------------------------------
    -- Flatten row_counts to a single total per run.
    --
    -- outer => TRUE keeps failed runs, whose ROW_COUNTS is NULL. An inner flatten
    -- would drop exactly the rows anyone is looking for.
    --
    -- _dlt_pipeline_state is excluded from the sum because it is dlt's own
    -- bookkeeping rather than loaded data. Counting it makes every run appear to have
    -- loaded one extra row, which is invisible until someone reconciles against the
    -- source and cannot work out where the surplus came from.
    -- ---------------------------------------------------------------------
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
    FROM WNBA_PROD_DB.OPS._DLT_RUNS r,
         LATERAL FLATTEN(input => r.ROW_COUNTS, outer => TRUE) f
    GROUP BY r._DLT_ID, r.PIPELINE, r.STATUS, r.LOAD_ID,
             r.FINISHED_AT, r.ERROR, r.RESOURCES
),

-- ---------------------------------------------------------------------
-- When _DLT_RUNS started collecting, which is NOT when telemetry started.
--
-- THERE ARE TWO DIFFERENT HISTORY BOUNDARIES AND USING THE WRONG ONE IS SILENT.
--   _DLT_RUNS has been written since the first pipeline run, 2026-08-01. The event
--   table was created 2026-08-08. A first draft of this view guarded
--   DLT_RECORD_MISSING on TELEMETRY_AVAILABLE, which is the event table's boundary,
--   and the column came back FALSE for all 42 rows: every genuinely missing record
--   predated the event table and was suppressed. A column that is always false does
--   not error and does not look broken.
--
--   Computed from the data so it stays right if the table is recreated, and so it
--   advances on its own if _DLT_RUNS is ever trimmed.
-- ---------------------------------------------------------------------
dlt_window AS (
    SELECT MIN(FINISHED_AT) AS DLT_RUNS_FROM FROM WNBA_PROD_DB.OPS._DLT_RUNS
)
SELECT
    t.PIPELINE,
    t.TASK_NAME,
    t.QUERY_ID,
    t.SERVICE_NAME,
    t.COMPUTE_POOL,

    -- Timings and resources come straight through from the control-plane view.
    t.RUN_STARTED_AT,
    t.RUN_ENDED_AT,
    t.DURATION_S,
    t.CONTAINER_SPAN_S,
    t.STARTUP_OVERHEAD_S,

    -- ---------------------------------------------------------------------
    -- TWO INDEPENDENT VERDICTS, KEPT SEPARATE ON PURPOSE.
    --
    -- TASK_STATE is what Snowflake saw. DLT_STATUS is what the pipeline recorded
    -- about itself. Collapsing them into one "status" column would throw away the
    -- interesting case, which is when they disagree: a Task can report SUCCEEDED
    -- while dlt recorded a failure, and that gap is a bug worth a page in itself.
    -- ---------------------------------------------------------------------
    t.STATE                                                        AS TASK_STATE,
    d.STATUS                                                       AS DLT_STATUS,
    (t.STATE = 'SUCCEEDED' AND d.STATUS IS DISTINCT FROM 'ok')     AS OUTCOME_DISAGREES,

    -- ---------------------------------------------------------------------
    -- _DLT_RUNS UNDER-REPORTS FAILURES, AND THIS COLUMN IS HOW YOU SEE IT.
    --
    -- record_run is called from inside run_pipeline, so a spec rejected by validate()
    -- dies several frames earlier and is never recorded at all. The gap is not random:
    -- the worse the failure, the earlier it happens, the less likely _DLT_RUNS is to
    -- mention it. Measured over one week, 22 Task failures produced 17 rows.
    --
    -- So a NULL here is a finding rather than an absence, and it is deliberately not
    -- conflated with a failed run. Anything built on _DLT_RUNS alone reads rosier
    -- than reality, which is why V_TASK_RUNS and not _DLT_RUNS is the spine.
    --
    -- Guarded on the _DLT_RUNS boundary, NOT on TELEMETRY_AVAILABLE. See dlt_window
    -- above: those are two different dates a week apart, and using the telemetry one
    -- made this column false for every row in the table.
    -- ---------------------------------------------------------------------
    (d._DLT_ID IS NULL AND t.RUN_STARTED_AT >= w.DLT_RUNS_FROM)    AS DLT_RECORD_MISSING,

    d.ROWS_LOADED,
    d.ROW_COUNTS,                       -- per-table counts, keyed by table name
    d.LOAD_ID,
    d.RESOURCES,                        -- non-NULL means a partial run (--resource)

    -- dlt's exception string is the useful error. The Task message only ever says
    -- "Exited with status: FAILED", so it is the fallback and not the first choice.
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
WHERE t.PIPELINE LIKE 'wnba\_%' ESCAPE '\\';

GRANT SELECT ON VIEW WNBA_PROD_DB.OPS.V_PIPELINE_RUNS TO ROLE DLT_DEV_ROLE;
