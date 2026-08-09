-- =============================================================================
-- ops/02_log_lines.sql
-- Purpose : Parsed SPCS job container log lines as a REAL TABLE, one row per
--           line, fed incrementally by an append-only stream. V_LOG_LINES
--           survives as a thin passthrough so no consumer changes.
-- Run as  : DLT_LOADER_ROLE, which owns it, matching every other prod object.
-- Prerequisites : ops/01_event_table.sql (event table, change tracking, and the
--                 CREATE TABLE / CREATE STREAM grants).
-- Apply   : make setup-ops CONFIRM=1
--
-- WHY THIS STOPPED BEING A VIEW
--   The original view was the right call at 74,000 rows and a few reads a day, and
--   its header said so. What killed it was the layer above: every uncached dashboard
--   query against the run views cost 4.6 to 6.0 seconds, compilation (2.5-3.6s)
--   exceeding execution, because Snowflake re-expanded and re-executed the whole
--   regex parse per query and the result cache was disqualified throughout
--   (CURRENT_TIMESTAMP() and metadata table functions). A dynamic table was
--   considered again and rejected again: it refreshes on a clock whether or not
--   data arrived, and is up to TARGET_LAG stale exactly when an ops view is read.
--
--   This table is the third answer: the parse runs ONCE per data arrival, driven by
--   the stream below and the triggered task in ops/04. Reads are plain table scans.
--   Retention decouples as a bonus: parsed lines keep 90 days (ops/05) while the
--   raw event table keeps 30.
--
-- THE PARSE SQL LIVES IN ops/04, NOT HERE.
--   SP_OBS_REFRESH owns the INSERT that fills this table, so the regex parse and
--   the four-wire-formats narrative (dlt / stdlib / structured / continuation,
--   POSIX-ERE bracket classes, the duplicate-emission note) moved there with it.
--   One copy of the parse, one place to read about it. This file owns the SHAPE:
--   the table, the stream, and the compatibility view.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- 1. The table. Column set is exactly the old view's output, plus nothing:
-- consumers SELECT * through V_LOG_LINES and must see the same columns.
--
-- EVENT_TS is TIMESTAMP_NTZ holding UTC because the event table's TIMESTAMP is,
-- and ops/04 depends on that fact for its boundary comparisons (see the
-- CONVERT_TIMEZONE note there). Do not "fix" the type here.
--
-- IF NOT EXISTS, never OR REPLACE: this table accumulates history that the raw
-- event table trims away after 30 days. Replacing it destroys the only copy.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.LOG_LINES (
    EVENT_TS        TIMESTAMP_NTZ,
    QUERY_ID        VARCHAR,
    SERVICE_NAME    VARCHAR,
    CONTAINER_NAME  VARCHAR,
    LOG_FORMAT      VARCHAR,
    SEVERITY        VARCHAR,
    LOGGER_NAME     VARCHAR,
    PIPELINE        VARCHAR,
    MESSAGE         VARCHAR,
    RAW_LINE        VARCHAR
)
COMMENT = 'One row per SPCS job container log line, parsed by SP_OBS_REFRESH (ops/04). Fed from STREAM_OBS_LOGS; retention 90d (ops/05), decoupled from the 30d raw event table.';

-- ---------------------------------------------------------------------------
-- 2. The stream. One stream per consumer, and this one belongs to the log parse
-- alone: any DML that reads a stream advances the WHOLE offset on commit, WHERE
-- clause notwithstanding, so a second reader would silently see nothing.
-- ops/03 has its own stream on the same table for exactly this reason.
--
-- APPEND_ONLY is load-bearing twice over: SPCS only ever inserts, and the weekly
-- retention DELETE in ops/05 would otherwise land ~65,000 delete records here
-- every Sunday and re-fire the refresh task for nothing.
--
-- SHOW_INITIAL_ROWS makes the FIRST consumption return the entire table as of
-- stream creation plus everything since, exactly once, transactionally. The
-- bootstrap IS the first drain: no separate backfill path, no quiet window, no
-- seam between history and increment.
--
-- IF NOT EXISTS, never OR REPLACE: replacing this stream re-arms
-- SHOW_INITIAL_ROWS and the next drain re-emits the entire event table as
-- duplicates. Recreating it deliberately is how a full rebuild works, and only
-- SP_OBS_REFRESH(TRUE) does that, with the refresh task suspended.
-- ---------------------------------------------------------------------------
CREATE STREAM IF NOT EXISTS DLT_DB.OPS.STREAM_OBS_LOGS
    ON EVENT TABLE DLT_DB.OPS.DLT_EVENTS
    APPEND_ONLY = TRUE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'Feeds the log-line parse in SP_OBS_REFRESH. One stream per consumer; ops/03 has its own. Never OR REPLACE casually: SHOW_INITIAL_ROWS re-arms.';

-- ---------------------------------------------------------------------------
-- 3. The compatibility view. Everything that read V_LOG_LINES keeps working,
-- dashboard log endpoints included; only the innards changed. COPY GRANTS keeps
-- OPS_DASHBOARD_ROLE's SELECT alive across the redefinition.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW DLT_DB.OPS.V_LOG_LINES
    COPY GRANTS
    COMMENT = 'Thin passthrough over DLT_DB.OPS.LOG_LINES (materialised 2026-08; parse lives in SP_OBS_REFRESH, ops/04).'
AS
SELECT * FROM DLT_DB.OPS.LOG_LINES;

GRANT SELECT ON TABLE DLT_DB.OPS.LOG_LINES  TO ROLE DLT_DEV_ROLE;
GRANT SELECT ON VIEW  DLT_DB.OPS.V_LOG_LINES TO ROLE DLT_DEV_ROLE;
