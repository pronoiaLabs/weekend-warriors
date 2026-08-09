-- =============================================================================
-- 05_dbt_trigger.sql (wnba) -- event-driven dbt build after ingestion
-- =============================================================================
-- Chain: dlt load succeeds -> one INSERT lands in RAW._DLT_LOADS -> the
-- append-only stream below has data -> the triggered task fires (no schedule;
-- idle costs nothing) -> the procedure drains the stream into an audit table
-- and runs EXECUTE DBT PROJECT for this sport. A FAILED load never inserts
-- into _DLT_LOADS, so failures never trigger a rebuild, structurally.
--
-- Conventions this file obeys (verified in WORKFLOW-4.md Phase 0):
--   * The task name avoids the DLT_TASK_ prefix: DLT_DB.OPS.V_TASK_RUNS turns
--     anything matching it into a pipeline row (see sql/ops/05_retention.sql
--     for the original warning). Living in <SPORT>_PROD_DB.OPS also keeps it
--     out of that view's DLT_DB filter entirely.
--   * This task is NOT managed by generate_tasks.py: make tasks-suspend /
--     tasks-apply / tasks-resume do not touch it. Suspend-before-alter is
--     built into this file instead, and the RESUME at the bottom is not
--     redundant: CREATE OR ALTER TASK leaves a task suspended.
--   * The DML drain in the procedure is mandatory, not an audit nicety: a
--     stream that is only read keeps SYSTEM$STREAM_HAS_DATA true and the task
--     re-fires every interval forever, billing DBT_WH (measured: 4 fires in
--     90 seconds). Drain-first also means a load landing mid-build simply
--     re-triggers after this one finishes.
--   * ENVIRONMENT is explicit because the project objects default to dev;
--     omitting it silently builds the wrong environment.
--   * A partial dbt failure raises a real SQL error (verified), so failures
--     land in TASK_HISTORY with ERROR_MESSAGE and count toward
--     SUSPEND_TASK_AFTER_NUM_FAILURES. No result inspection is needed.
--   * The 900s trigger interval coalesces: a burst of loads inside the window
--     produces one build that drains all of them (verified with 3 inserts ->
--     1 run). Evaluations that find no data are SKIPPED at zero cost.
--
-- Kill switch:  ALTER TASK WNBA_PROD_DB.OPS.DBT_BUILD_WNBA SUSPEND;
-- (ingestion untouched; the stream accumulates and is drained on resume;
-- staleness grace ~14 days, re-create the stream if suspended longer, and
-- also if dlt ever recreates _DLT_LOADS itself.)
--
-- History: SNOWFLAKE.ACCOUNT_USAGE.DBT_PROJECT_EXECUTION_HISTORY plus
-- TASK_HISTORY in this database. Not visible in V_TASK_RUNS, by design.
--
-- ORDER PREREQUISITE: the GRANT ON DBT PROJECT below needs the project
-- object to exist, so on a fresh account run
-- make -C ../dbt-pipelines deploy-sport SPORT=wnba BEFORE this file.
--
-- Apply with make setup-source SOURCE=wnba CONFIRM=1.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: grants and ownership (idempotent; roles from sql/base/04)
-- -----------------------------------------------------------------------------

USE ROLE SYSADMIN;

GRANT USAGE ON DATABASE WNBA_PROD_DB TO ROLE DBT_RUNNER_ROLE;
GRANT USAGE ON SCHEMA WNBA_PROD_DB.RAW TO ROLE DBT_RUNNER_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA WNBA_PROD_DB.RAW TO ROLE DBT_RUNNER_ROLE;

-- USAGE is load-bearing beyond navigation: a task cannot run if its owner
-- role lacks USAGE on the task's schema (verified the hard way in Phase 0).
GRANT USAGE, CREATE STREAM, CREATE TABLE, CREATE PROCEDURE, CREATE TASK
  ON SCHEMA WNBA_PROD_DB.OPS TO ROLE DBT_RUNNER_ROLE;

-- The invoke privilege for EXECUTE DBT PROJECT is USAGE on the object
-- (verified; the docs disagree with themselves). Object created by
-- make -C ../dbt-pipelines deploy-sport SPORT=wnba.
GRANT USAGE ON DBT PROJECT DLT_DB.DEPLOY.CORTEX_LIFECYCLE_WNBA TO ROLE DBT_RUNNER_ROLE;

USE ROLE DLT_LOADER_ROLE;

GRANT SELECT ON ALL TABLES IN SCHEMA WNBA_PROD_DB.RAW TO ROLE DBT_RUNNER_ROLE;

-- Streams need change tracking on the source table, and creating a stream as
-- a non-owner does not enable it. Explicit, as the table owner.
ALTER TABLE WNBA_PROD_DB.RAW._DLT_LOADS SET CHANGE_TRACKING = TRUE;

USE ROLE SYSADMIN;

-- Ownership transfer, not broad grants: dbt materializes with CREATE OR
-- REPLACE, which requires owning the existing object. SYSADMIN keeps full
-- access through the role hierarchy. Semantic views are their own object
-- class with their own bulk-transfer form (verified). Agents in ANALYTICS
-- stay SYSADMIN-owned: dbt does not manage them.
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA WNBA_PROD_DB.PREP TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL VIEWS IN SCHEMA WNBA_PROD_DB.PREP TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA WNBA_PROD_DB.PREP TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA WNBA_PROD_DB.CORE TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL VIEWS IN SCHEMA WNBA_PROD_DB.CORE TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA WNBA_PROD_DB.CORE TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA WNBA_PROD_DB.ANALYTICS TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL VIEWS IN SCHEMA WNBA_PROD_DB.ANALYTICS TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL SEMANTIC VIEWS IN SCHEMA WNBA_PROD_DB.ANALYTICS TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA WNBA_PROD_DB.ANALYTICS TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;

-- -----------------------------------------------------------------------------
-- Section 2: the trigger machinery, owned by DBT_RUNNER_ROLE
-- -----------------------------------------------------------------------------

USE ROLE DBT_RUNNER_ROLE;

CREATE STREAM IF NOT EXISTS WNBA_PROD_DB.OPS.DBT_LOADS_STREAM
  ON TABLE WNBA_PROD_DB.RAW._DLT_LOADS APPEND_ONLY = TRUE
  COMMENT = 'One row per successful dlt load; consumed only by DBT_BUILD_WNBA (one stream per consumer).';

CREATE TABLE IF NOT EXISTS WNBA_PROD_DB.OPS.DBT_TRIGGER_LOADS (
  LOAD_ID             VARCHAR,
  PIPELINE            VARCHAR,
  STATUS              NUMBER,
  -- TIMESTAMP_TZ matches _DLT_LOADS.INSERTED_AT exactly: the drain INSERT
  -- selects it straight through, and a TZ->NTZ mismatch fails the INSERT
  -- (found live; the Phase 0 spike's fake table was NTZ and hid it).
  INSERTED_AT         TIMESTAMP_TZ,
  DRAINED_AT          TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Audit: which loads triggered which dbt build. The INSERT that fills this is also the stream consumption that stops re-triggering.';

CREATE OR REPLACE PROCEDURE WNBA_PROD_DB.OPS.SP_DBT_BUILD()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Drain DBT_LOADS_STREAM, then dbt build for WNBA. Caller''s rights: EXECUTE DBT PROJECT requires it.'
EXECUTE AS CALLER
AS
$$
DECLARE
  drained INTEGER;
BEGIN
  -- Drain FIRST. This is the stream consumption; without it the task
  -- re-fires every interval forever.
  INSERT INTO WNBA_PROD_DB.OPS.DBT_TRIGGER_LOADS (LOAD_ID, PIPELINE, STATUS, INSERTED_AT, DRAINED_AT)
    SELECT LOAD_ID, SCHEMA_NAME, STATUS, INSERTED_AT, CURRENT_TIMESTAMP()
    FROM WNBA_PROD_DB.OPS.DBT_LOADS_STREAM;
  drained := SQLROWCOUNT;

  -- SYSTEM$STREAM_HAS_DATA tolerates false positives; do not build on one.
  IF (drained = 0) THEN
    RETURN 'no-op: stream was empty';
  END IF;

  -- Explicit ENVIRONMENT: the project object defaults to dev. A partial dbt
  -- failure raises here, failing the task with the message in TASK_HISTORY.
  EXECUTE DBT PROJECT DLT_DB.DEPLOY.CORTEX_LIFECYCLE_WNBA
    ARGS = 'build'
    ENVIRONMENT = 'wnba_prod';

  RETURN 'built after ' || drained || ' load(s)';
END;
$$;

-- CREATE OR ALTER TASK refuses to touch a started task; suspend first.
ALTER TASK IF EXISTS WNBA_PROD_DB.OPS.DBT_BUILD_WNBA SUSPEND;

CREATE OR ALTER TASK WNBA_PROD_DB.OPS.DBT_BUILD_WNBA
  WAREHOUSE = DBT_WH
  USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 900
  USER_TASK_TIMEOUT_MS = 3600000
  COMMENT = 'dbt build for WNBA on new RAW loads. NOT managed by generate_tasks.py; history in SNOWFLAKE.ACCOUNT_USAGE.DBT_PROJECT_EXECUTION_HISTORY.'
  WHEN SYSTEM$STREAM_HAS_DATA('WNBA_PROD_DB.OPS.DBT_LOADS_STREAM')
AS
  CALL WNBA_PROD_DB.OPS.SP_DBT_BUILD();

-- Not redundant: CREATE OR ALTER TASK leaves the task suspended.
ALTER TASK WNBA_PROD_DB.OPS.DBT_BUILD_WNBA RESUME;
