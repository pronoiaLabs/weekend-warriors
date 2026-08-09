-- =============================================================================
-- ops/01_event_table.sql
-- Purpose : A dedicated event table for SPCS job telemetry, bound to DLT_DB, plus
--           the small warehouse the observability layer refreshes on.
-- Run as  : SYSADMIN, with one ACCOUNTADMIN block at the end. Binding an event
--           table to a database is not a privilege SYSADMIN holds.
-- Prerequisites : base/02_control_plane.sql (DLT_DB and DLT_DB.OPS must exist).
-- Apply   : make setup-ops CONFIRM=1
--
-- WHY A DEDICATED TABLE AND NOT SNOWFLAKE.TELEMETRY.EVENTS
--   The shared table already receives these logs and would need no setup at all.
--   Three reasons not to build on it, and only the first two survive the move from
--   a dynamic table to views:
--
--     Retention. Event tables are never auto-purged, and ops/04 has to DELETE from
--     this one on a schedule. DELETE on SNOWFLAKE.TELEMETRY.EVENTS is permitted but
--     it is a shared object owned by the account, and trimming it on our cadence
--     imposes our retention policy on anything else that ever logs there.
--
--     Ownership and grants. DLT_LOADER_ROLE owns this table and can be granted
--     exactly SELECT and DELETE. Access to the shared table is an account-level
--     concern that cannot be scoped to this project's roles.
--
--     Change tracking, which was the original and now weakest reason: it cannot be
--     set on an object in the SNOWFLAKE database, and a dynamic table needs it. The
--     modelling layer is views, so this no longer decides anything. Recorded because
--     it was the argument that carried the decision, and it should not be quoted
--     back later as if it still does.
--
-- THE BINDING MUST BE AT ACCOUNT LEVEL. A DATABASE-LEVEL BINDING DOES NOTHING HERE.
--   This is the opposite of what the general event-table documentation implies, and
--   it cost a failed verification to find, so it is written down rather than left as
--   folklore.
--
--   "Event table overview" states that a database-level EVENT_TABLE overrides the
--   account-level one for objects in that database. That is true for UDFs and stored
--   procedures. It is NOT true for Snowpark Container Services: the SPCS monitoring
--   page says container stdout is captured "into the event table configured for your
--   account" and directs you to SHOW PARAMETERS ... IN ACCOUNT specifically.
--
--   Measured 2026-08-08. With EVENT_TABLE set on DLT_DB and NOT on the account, a
--   fresh job service in DLT_DB.DEPLOY wrote all 192 of its rows to
--   SNOWFLAKE.TELEMETRY.EVENTS and zero to DLT_DB.OPS.DLT_EVENTS. The database-level
--   parameter read back correctly as level=DATABASE the whole time, so the binding
--   looked applied and was simply not consulted.
--
--   Both bindings are set below. The account one is what actually routes SPCS
--   telemetry; the database one costs nothing, points at the same table so the two
--   can never diverge, and covers any non-SPCS object in DLT_DB.
--
-- SETTING THE PARAMETER IS NOT ENOUGH. A LIVE COMPUTE POOL NODE KEEPS THE OLD ONE.
--   An SPCS node resolves its event table when the NODE starts, not per job, so a
--   pool with a warm node goes on writing to the previous table indefinitely.
--   `make run-spcs` drops and recreates the SERVICE each run, which is not the same
--   thing and does not help.
--
--   Measured 2026-08-08, immediately after the account binding above was applied:
--   a job on the warm DLT_DEV_POOL node still wrote every log line to
--   SNOWFLAKE.TELEMETRY.EVENTS. `ALTER COMPUTE POOL DLT_DEV_POOL SUSPEND`, then one
--   more run on the freshly provisioned node, and all 145 log rows plus 36 metric
--   rows landed in DLT_EVENTS.
--
--   So after applying this file: cycle any pool that has live nodes. A pool already
--   SUSPENDED with zero nodes needs nothing, because its next job provisions a new
--   node that reads the new binding. DLT_POOL was suspended at the time of writing,
--   which is why production needed no intervention.
--
--   The run that straddled the change split across both tables: its logs went to the
--   old one and eight of its metrics, flushed later, to the new one. Expect exactly
--   one such run and do not read it as a partial failure.
--
-- WHY TAKING OVER THE ACCOUNT BINDING IS SAFE HERE, WHICH IS NOT A GENERAL CLAIM
--   Redirecting the account event table moves telemetry for everything in the
--   account, so it deserves a check rather than an assumption. Over the preceding
--   14 days SNOWFLAKE.TELEMETRY.EVENTS held 14,975 rows and every one of them was
--   snow.service.type = 'Job' in DLT_DB: this project's own pipelines and nothing
--   else. There is no other telemetry to disturb. Re-run that check before copying
--   this into an account that hosts anything else.
--
-- CUTOVER CONSEQUENCE, WORTH KNOWING BEFORE YOU RUN IT
--   Rows already collected stay in SNOWFLAKE.TELEMETRY.EVENTS forever. History
--   splits at the moment of binding. That is why this file runs BEFORE metrics are
--   enabled in the job spec: every metric ever emitted then lands here, and the
--   metric series never has a seam in it. The log series does, and that is accepted.
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. Observability warehouse
--
-- Deliberately not DLT_WH. That warehouse is a Gen2 multi-cluster sized for MERGE
-- and COPY on the load path; charging dynamic-table refreshes to it would make
-- load cost and observability cost inseparable in METERING_HISTORY, and the whole
-- point of this layer is being able to answer what things cost.
--
-- XSMALL with a 60 second auto-suspend. The refresh workload is a handful of
-- nightly crons, not a stream.
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS DLT_OPS_WH
    WAREHOUSE_SIZE      = XSMALL
    WAREHOUSE_TYPE      = STANDARD
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'Dynamic-table refresh and retention for the dlt observability layer.';

GRANT USAGE   ON WAREHOUSE DLT_OPS_WH TO ROLE DLT_LOADER_ROLE;
GRANT OPERATE ON WAREHOUSE DLT_OPS_WH TO ROLE DLT_LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- 2. The event table
--
-- DATA_RETENTION_TIME_IN_DAYS = 1 PURGES NOTHING. It is Time Travel only.
--   Event tables are never auto-purged by Snowflake. Row retention is a scheduled
--   DELETE and lives in ops/04_retention.sql. One day is simply the default and is
--   enough to undo a mistaken DELETE.
--
--   AN EARLIER VERSION OF THIS FILE CLAIMED THIS SETTING WAS LOAD BEARING, because
--   incremental refresh of a dynamic table requires change tracking with non-zero
--   Time Travel. That reasoning died with the dynamic table: ops/02 is a plain view.
--   The claim is recorded here rather than quietly deleted, because a false rationale
--   left in a file is worse than no rationale, and this one would have justified
--   never touching a parameter that is in fact free to change.
--
-- CHANGE_TRACKING IS LOAD-BEARING AGAIN.
--   The modelling layer outgrew views: ops/02 and ops/03 now hang APPEND_ONLY
--   streams (STREAM_OBS_LOGS, STREAM_OBS_METRICS) off this table, and streams
--   require change tracking on their source. The "left on because it costs little"
--   era paid off exactly as predicted: it is what made the switch cheap.
-- ---------------------------------------------------------------------------
CREATE EVENT TABLE IF NOT EXISTS DLT_DB.OPS.DLT_EVENTS
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'SPCS container logs and platform metrics for dlt job services. Bound to DLT_DB.';

-- Belt and braces. Event tables are created with change tracking already on, but
-- the ops/02 and ops/03 streams hard-depend on it, so it is asserted rather than
-- assumed.
ALTER TABLE DLT_DB.OPS.DLT_EVENTS SET CHANGE_TRACKING = TRUE;

-- ---------------------------------------------------------------------------
-- 3. Grants
--
-- SELECT so the loader role can read telemetry and own the dynamic table over it.
-- DELETE so the retention task in ops/04 can trim it.
--
-- NO INSERT, deliberately. Rows arrive from the platform, not from any role, and
-- granting INSERT would suggest otherwise to the next person reading this.
-- ---------------------------------------------------------------------------
GRANT SELECT ON TABLE DLT_DB.OPS.DLT_EVENTS TO ROLE DLT_LOADER_ROLE;
GRANT DELETE ON TABLE DLT_DB.OPS.DLT_EVENTS TO ROLE DLT_LOADER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DLT_EVENTS TO ROLE DLT_DEV_ROLE;

-- The observability objects in ops/02 through ops/05 are created and owned by
-- DLT_LOADER_ROLE, matching every other production object, so the privileges belong
-- on the schema.
--
-- The layer IS now materialised (ops/02-04: tables fed by streams and a triggered
-- task), so the loader role needs the full set. A missing one fails at apply time
-- with `Insufficient privileges to operate on schema 'OPS'`, which names the schema
-- rather than the missing privilege and reads like a role problem; it is not.
-- (CREATE TASK and EXECUTE TASK ON ACCOUNT come from base/02_control_plane.sql.)
GRANT CREATE VIEW ON SCHEMA DLT_DB.OPS TO ROLE DLT_LOADER_ROLE;
GRANT CREATE TABLE, CREATE STREAM, CREATE PROCEDURE
   ON SCHEMA DLT_DB.OPS TO ROLE DLT_LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- 4. Bind the event table
--
-- ACCOUNT FIRST, AND IT IS THE ONE THAT MATTERS. See the header: SPCS container
-- telemetry reads the account-level parameter and ignores a database-level one.
-- Without this statement the table below stays empty forever while every parameter
-- reads back exactly as intended.
--
-- Safe here only because this account emits nothing but this project's own job
-- telemetry, which was checked rather than assumed. Not a general recommendation.
-- ---------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
ALTER ACCOUNT SET EVENT_TABLE = DLT_DB.OPS.DLT_EVENTS;

-- Belt and braces, and free. Does NOT affect SPCS, which is why it is not on its
-- own. It points at the same table as the account binding, so the two cannot
-- disagree, and it covers any UDF or stored procedure created in DLT_DB later.
ALTER DATABASE DLT_DB SET EVENT_TABLE = DLT_DB.OPS.DLT_EVENTS;
USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- Verify, in this order. The second query is the half people skip, and skipping it
-- proves nothing: both tables could be receiving.
--
--   SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT;
--     -> value = DLT_DB.OPS.DLT_EVENTS, level = ACCOUNT
--     A blank level means the default is still in force and SPCS will keep writing
--     to SNOWFLAKE.TELEMETRY.EVENTS. Check ACCOUNT, not DATABASE: the database-level
--     parameter reads back correctly whether or not it is doing anything.
--
--   -- then run one dev job: make run-spcs NAME=sample
--   SELECT COUNT(*) FROM DLT_DB.OPS.DLT_EVENTS
--    WHERE RESOURCE_ATTRIBUTES:"snow.service.type"::string = 'Job';   -- expect > 0
--
--   SELECT MAX(TIMESTAMP) FROM SNOWFLAKE.TELEMETRY.EVENTS
--    WHERE RESOURCE_ATTRIBUTES:"snow.service.type"::string = 'Job';   -- expect UNCHANGED
-- ---------------------------------------------------------------------------
