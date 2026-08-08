-- =============================================================================
-- ops/05_retention.sql
-- Purpose : Trim DLT_DB.OPS.DLT_EVENTS on a schedule. Event tables are NEVER
--           auto-purged by Snowflake.
-- Run as  : DLT_LOADER_ROLE, which owns the event table and already holds
--           EXECUTE TASK ON ACCOUNT and CREATE TASK ON SCHEMA DLT_DB.OPS from
--           base/02_control_plane.sql.
-- Prerequisites : ops/01_event_table.sql.
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
-- WHY THE NAME AVOIDS THE dlt_task_ PREFIX
--   ops/04 builds V_TASK_RUNS by filtering task history on `NAME ILIKE 'DLT_TASK_%'`
--   and turning whatever matches into a pipeline row. A retention task called
--   dlt_task_retention would therefore appear in the run summary forever as a
--   pipeline that loads nothing, and it is not managed by generate_tasks.py either,
--   so `make tasks-suspend` and `make tasks-apply` would not touch it. Two problems
--   from one naming choice, both silent.
--
-- THE RESUME AT THE BOTTOM IS NOT REDUNDANT
--   CREATE OR ALTER TASK leaves a task suspended, and this file is applied by hand by
--   `make setup-ops` with no `--resume` pass behind it, unlike the generated pipeline
--   Tasks. Without the explicit RESUME this task is created and never runs, and
--   nothing anywhere reports that: the table simply grows.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

CREATE OR ALTER TASK DLT_DB.OPS.DLT_EVENTS_RETENTION
    WAREHOUSE = DLT_OPS_WH
    -- Sunday 04:30 UTC. Every pipeline cron sits between 08:00 and 23:00 UTC, so this
    -- is more than three hours clear of the nearest one. The DELETE therefore never
    -- contends with a load, and the rewrite it causes lands in a quiet window.
    SCHEDULE  = 'USING CRON 30 4 * * 0 UTC'
    COMMENT   = 'Delete DLT_EVENTS rows older than 30 days. Event tables never auto-purge.'
AS
    DELETE FROM DLT_DB.OPS.DLT_EVENTS
    WHERE TIMESTAMP < DATEADD('day', -30, CURRENT_TIMESTAMP());

ALTER TASK DLT_DB.OPS.DLT_EVENTS_RETENTION RESUME;

-- ---------------------------------------------------------------------------
-- WHAT THIRTY DAYS COSTS YOU DOWNSTREAM, STATED SO IT IS A DECISION AND NOT A
-- DISCOVERY.
--
--   ops/02 and ops/03 are views over this table, so they see exactly what it holds.
--   Deleting here deletes there, immediately and with no warning.
--
--   ops/04 is different, and the asymmetry matters: it reads task history from
--   ACCOUNT_USAGE, which retains 365 days. So a run older than thirty days keeps its
--   outcome, its duration and its error message, and loses its logs and its resource
--   samples. That is the right trade for an ops view. It is also why ops/04 carries
--   TELEMETRY_AVAILABLE rather than reporting those runs as crashed containers.
--
--   To keep parsed logs longer than raw ones, ops/02 would have to become a real
--   table fed by a task from an APPEND_ONLY stream on this table. Until someone wants
--   that, these two retentions are necessarily the same number.
-- ---------------------------------------------------------------------------
