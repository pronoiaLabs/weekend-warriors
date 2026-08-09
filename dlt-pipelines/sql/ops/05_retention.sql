-- =============================================================================
-- ops/05_retention.sql
-- Purpose : Trim DLT_DB.OPS.DLT_EVENTS on a schedule (event tables are NEVER
--           auto-purged by Snowflake), and trim the materialised observability
--           tables on their own, longer, schedules.
-- Run as  : DLT_LOADER_ROLE, which owns all of it and already holds
--           EXECUTE TASK ON ACCOUNT and CREATE TASK ON SCHEMA DLT_DB.OPS from
--           base/02_control_plane.sql.
-- Prerequisites : ops/01 through ops/04.
-- Apply   : make setup-ops CONFIRM=1
--
-- DATA_RETENTION_TIME_IN_DAYS DOES NOT DO THIS.
--   That parameter is Time Travel. It governs how far back you can query the table
--   as it used to be; it deletes nothing. Left alone this table grows forever, at
--   roughly 15,000 log rows and 400 metric rows a week for a seventeen-pipeline
--   fleet. Thirty days settles at about 65,000 rows, which is nothing, and that is
--   the point: the cost of this task is negligible and the cost of not having it is
--   unbounded.
--
-- THE WEEKLY DELETE IS INVISIBLE TO THE ops/02+03 STREAMS ONLY BECAUSE THEY ARE
-- APPEND_ONLY. A standard stream would receive ~65,000 delete records every
--   Sunday and re-fire OBS_REFRESH for nothing. Load-bearing, not stylistic; if
--   anyone ever recreates those streams without APPEND_ONLY, this DELETE is the
--   thing that finds out.
--
-- WHY THE NAMES AVOID THE dlt_task_ PREFIX
--   ops/04 filters task history on `NAME ILIKE 'DLT_TASK_%'` and turns whatever
--   matches into a pipeline row. A retention task called dlt_task_retention would
--   appear in the run summary forever as a pipeline that loads nothing, and it is
--   not managed by generate_tasks.py either, so `make tasks-suspend` and
--   `make tasks-apply` would not touch it. Two problems from one naming choice,
--   both silent.
--
-- THE RESUMES AT THE BOTTOM ARE NOT REDUNDANT
--   CREATE OR ALTER TASK leaves a task suspended, and this file is applied by hand
--   by `make setup-ops` with no `--resume` pass behind it. Without the explicit
--   RESUME a task is created and never runs, and nothing anywhere reports that:
--   the tables simply grow.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

CREATE OR ALTER TASK DLT_DB.OPS.DLT_EVENTS_RETENTION
    WAREHOUSE = DLT_OPS_WH
    -- Sunday 04:30 UTC. Every pipeline cron sits between 02:00 and 23:00 UTC, so
    -- this window is as quiet as the calendar gets; ops/06's retention runs at
    -- 04:45 and OBS_RETENTION below at 05:00, deliberately staggered.
    SCHEDULE  = 'USING CRON 30 4 * * 0 UTC'
    COMMENT   = 'Delete DLT_EVENTS rows older than 30 days. Event tables never auto-purge.'
AS
    DELETE FROM DLT_DB.OPS.DLT_EVENTS
    WHERE TIMESTAMP < DATEADD('day', -30, CURRENT_TIMESTAMP());

ALTER TASK DLT_DB.OPS.DLT_EVENTS_RETENTION RESUME;

-- ---------------------------------------------------------------------------
-- Retention for the materialised layer. This is the decoupling the old closing
-- note of this file promised: parsed lines outlive their raw rows 3x (90d vs
-- 30d), and the run-summary tables keep a full year to match what
-- ACCOUNT_USAGE.TASK_HISTORY could reconstruct anyway.
--
-- A proc rather than four tasks: one task per statement would buy nothing but
-- scheduling noise, and the SP_DBT_OBS_RETENTION precedent (ops/06) already
-- established the shape.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_OBS_RETENTION()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Weekly trim of the materialised observability tables: 90d parsed logs/metrics, 365d run summaries.'
EXECUTE AS CALLER
AS
$$
DECLARE
  logs_n    INTEGER DEFAULT 0;
  metrics_n INTEGER DEFAULT 0;
  tr_n      INTEGER DEFAULT 0;
  pr_n      INTEGER DEFAULT 0;
BEGIN
  DELETE FROM DLT_DB.OPS.LOG_LINES
   WHERE EVENT_TS < DATEADD('day', -90, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ);
  logs_n := SQLROWCOUNT;

  DELETE FROM DLT_DB.OPS.METRIC_SAMPLES
   WHERE EVENT_TS < DATEADD('day', -90, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ);
  metrics_n := SQLROWCOUNT;

  DELETE FROM DLT_DB.OPS.TASK_RUNS
   WHERE RUN_STARTED_AT < DATEADD('day', -365, CURRENT_TIMESTAMP());
  tr_n := SQLROWCOUNT;

  DELETE FROM DLT_DB.OPS.PIPELINE_RUNS
   WHERE RUN_STARTED_AT < DATEADD('day', -365, CURRENT_TIMESTAMP());
  pr_n := SQLROWCOUNT;

  RETURN 'trimmed: log_lines ' || logs_n || ', metric_samples ' || metrics_n
      || ', task_runs ' || tr_n || ', pipeline_runs ' || pr_n;
END;
$$;

CREATE OR ALTER TASK DLT_DB.OPS.OBS_RETENTION
    WAREHOUSE = DLT_OPS_WH
    -- Sunday 05:00 UTC: 04:30 (raw events) and 04:45 (dbt observability) are
    -- taken; staggered so the three trims never contend.
    SCHEDULE  = 'USING CRON 0 5 * * 0 UTC'
    COMMENT   = 'Weekly trim of LOG_LINES / METRIC_SAMPLES (90d) and TASK_RUNS / PIPELINE_RUNS (365d). NOT managed by generate_tasks.py.'
AS
    CALL DLT_DB.OPS.SP_OBS_RETENTION();

ALTER TASK DLT_DB.OPS.OBS_RETENTION RESUME;

-- ---------------------------------------------------------------------------
-- THE RETENTION ASYMMETRY, STATED SO IT IS A DECISION AND NOT A DISCOVERY.
--
--   Raw DLT_EVENTS keeps 30 days; the parsed LOG_LINES / METRIC_SAMPLES keep 90.
--   Between day 30 and day 90 a run's lines exist ONLY in the parsed tables: the
--   raw row is gone, and a FULL rebuild (SP_OBS_REFRESH(TRUE)) can only recover
--   what raw still holds. Rebuilds are therefore lossy beyond 30 days, which is
--   accepted: the parsed copy IS the archive.
--
--   TASK_RUNS and PIPELINE_RUNS keep 365 days, matching ACCOUNT_USAGE, so a run
--   older than 90 days keeps its outcome, duration and error and loses its log
--   detail. Same trade the view stack made, now with a wider window.
-- ---------------------------------------------------------------------------
