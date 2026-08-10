-- =============================================================================
-- ops/03_metrics.sql
-- Purpose : SPCS platform metric samples as a REAL TABLE, one row per sample,
--           fed incrementally by an append-only stream. V_METRICS survives as a
--           thin passthrough so no consumer changes.
-- Run as  : DLT_LOADER_ROLE, which owns it.
-- Prerequisites : ops/01_event_table.sql.
-- Apply   : make setup-ops CONFIRM=1
--
-- Same materialisation story as ops/02, same decode-lives-in-ops/04 rule: the
-- JSON extraction and METRIC_GROUP CASE ladder moved into SP_OBS_REFRESH with
-- the INSERT that runs them. This file owns the shape.
--
-- WHY METRICS ARE A SEPARATE TABLE FROM LOGS (unchanged from the view era)
--   Logs and metrics share an event table and nothing else. A log row has a message,
--   a severity and a logger; a metric row has a name and a number and no message at
--   all. One table for both gives every row half a table of NULLs.
--
-- READ THE DENSITY WARNING BEFORE BUILDING ANYTHING ON THIS (unchanged)
--   The scrape interval is about 30 seconds and pipeline runs are 53 to 130 seconds,
--   so a run yields 1 to 4 samples of each varying metric. MAX() over a run is a
--   sampled reading, not a peak; a memory spike that kills a container will usually
--   fall between scrapes and never appear. Useful as a trend across many runs,
--   misleading as a per-run maximum. ops/04 carries a sample count beside every
--   aggregate for exactly this reason.
--
-- WHAT IS ACTUALLY EMITTED, MEASURED RATHER THAN READ OFF THE DOCUMENTATION
--   16 distinct metrics across four groups. `storage` has produced ZERO rows ever
--   (these containers mount no volumes). There is no container exit code:
--   `container.state.last.finished.exitcode` appears in the documentation and not
--   in the output. Failure reason still comes from TASK_HISTORY.ERROR_MESSAGE.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

-- Column set is exactly the old view's output. IF NOT EXISTS, never OR REPLACE:
-- this table outlives the raw rows it was parsed from.
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.METRIC_SAMPLES (
    EVENT_TS             TIMESTAMP_NTZ,
    QUERY_ID             VARCHAR,
    SERVICE_NAME         VARCHAR,
    COMPUTE_POOL         VARCHAR,
    NODE_INSTANCE_FAMILY VARCHAR,
    NODE_ID              VARCHAR,
    METRIC_NAME          VARCHAR,
    METRIC_VALUE         FLOAT,
    METRIC_UNIT          VARCHAR,
    METRIC_TYPE          VARCHAR,
    METRIC_DESCRIPTION   VARCHAR,
    METRIC_GROUP         VARCHAR
)
COMMENT = 'One row per SPCS platform metric sample, decoded by SP_OBS_REFRESH (ops/04). Fed from STREAM_OBS_METRICS; retention 90d (ops/05).';

-- One stream per consumer (see ops/02 for why that rule exists), APPEND_ONLY so
-- the weekly retention DELETE is invisible, SHOW_INITIAL_ROWS so the first drain
-- is the backfill. IF NOT EXISTS, never OR REPLACE.
CREATE STREAM IF NOT EXISTS DLT_DB.OPS.STREAM_OBS_METRICS
    ON EVENT TABLE DLT_DB.OPS.DLT_EVENTS
    APPEND_ONLY = TRUE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'Feeds the metric decode in SP_OBS_REFRESH. One stream per consumer; ops/02 has its own. Never OR REPLACE casually: SHOW_INITIAL_ROWS re-arms.';

CREATE OR REPLACE VIEW DLT_DB.OPS.V_METRICS
    COPY GRANTS
    COMMENT = 'Thin passthrough over DLT_DB.OPS.METRIC_SAMPLES (materialised 2026-08; decode lives in SP_OBS_REFRESH, ops/04).'
AS
SELECT * FROM DLT_DB.OPS.METRIC_SAMPLES;

GRANT SELECT ON TABLE DLT_DB.OPS.METRIC_SAMPLES TO ROLE DLT_DEV_ROLE;
GRANT SELECT ON VIEW  DLT_DB.OPS.V_METRICS      TO ROLE DLT_DEV_ROLE;
