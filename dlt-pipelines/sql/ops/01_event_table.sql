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
--   It cannot be used: it lives in the SNOWFLAKE shared database, change tracking
--   cannot be set on an object there, and change tracking is the prerequisite for
--   an incrementally refreshing dynamic table. Reading the shared table forecloses
--   the entire modelling layer, so the choice is made here rather than discovered
--   in ops/02.
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
-- DATA_RETENTION_TIME_IN_DAYS = 1 IS LOAD BEARING AND IS NOT ABOUT RETENTION.
--   Incremental refresh requires change tracking with NON-ZERO Time Travel
--   retention on every base object. At 0 the dynamic table in ops/02 either falls
--   back to a full refresh or refuses to create, and the error names change
--   tracking rather than retention, so it reads like a grant problem for an hour.
--
--   This parameter purges NOTHING. Event tables are never auto-purged by Snowflake;
--   row retention is a scheduled DELETE and lives in ops/04_retention.sql.
-- ---------------------------------------------------------------------------
CREATE EVENT TABLE IF NOT EXISTS DLT_DB.OPS.DLT_EVENTS
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'SPCS container logs and platform metrics for dlt job services. Bound to DLT_DB.';

-- Belt and braces. Event tables are created with change tracking already on, but
-- the dynamic table hard-depends on it, so it is asserted rather than assumed.
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

-- The dynamic table in ops/02 is created and owned by DLT_LOADER_ROLE, matching
-- every other production object, so the privilege belongs on the schema now.
GRANT CREATE DYNAMIC TABLE ON SCHEMA DLT_DB.OPS TO ROLE DLT_LOADER_ROLE;

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
