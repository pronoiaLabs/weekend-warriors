-- =============================================================================
-- sources/nfl/08_app_copy_task.sql
-- Purpose : After each NFL harvest, fire DLT_DB.OPS.dlt_task_nfl_app_to_postgres.
--           Snowflake task graphs cannot cross schemas (091413) and must share
--           one owner, so this wrapper lives next to DBT_HARVEST_NFL
--           (NFL_PROD_DB.OPS / DBT_RUNNER_ROLE) and CALL SP_APP_COPY_FIRE,
--           which EXECUTE TASKs the loader in DLT_DB.OPS unless a postgres
--           copy is already running. Shared instance with obs_to_postgres:
--           overlapping INSERT VALUES OOMs Postgres (measured 2026-08-24).
--           generate_tasks.py does not emit AFTER.
-- Run as  : DLT_LOADER_ROLE (OPERATE grant), then DBT_RUNNER_ROLE (wrapper)
-- Apply   : make setup-app-copy-trigger CONFIRM=1
--           (or this file after the standalone Task already exists)
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

-- The wrapper EXECUTE TASKs a Task it does not own. ACCOUNT-level
-- EXECUTE TASK is already on DBT_RUNNER_ROLE (base/04); OPERATE is the
-- object-level pair so a missing account grant cannot silently break this.
GRANT OPERATE ON TASK DLT_DB.OPS.dlt_task_nfl_app_to_postgres
  TO ROLE DBT_RUNNER_ROLE;
GRANT MONITOR ON TASK DLT_DB.OPS.dlt_task_nfl_app_to_postgres
  TO ROLE DBT_RUNNER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.TASK_RUNS TO ROLE DBT_RUNNER_ROLE;

-- Caller's rights so TASK_HISTORY and EXECUTE TASK run as DBT_RUNNER_ROLE
-- (OPERATE + MONITOR granted above). Owner's-rights metadata functions fail.
CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_APP_COPY_FIRE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  LET inflight INTEGER := (
    SELECT COUNT(*)
    FROM DLT_DB.OPS.TASK_RUNS
    WHERE PIPELINE IN ('obs_to_postgres', 'obs_to_postgres_resync',
                       'nfl_app_to_postgres')
      AND STATE IN ('EXECUTING', 'SCHEDULED')
  );
  IF (inflight > 0) THEN
    RETURN 'skipped: postgres copy already executing';
  END IF;

  LET live_app INTEGER := (
    SELECT COUNT(*)
    FROM TABLE(DLT_DB.INFORMATION_SCHEMA.TASK_HISTORY(
      TASK_NAME => 'DLT_TASK_NFL_APP_TO_POSTGRES', RESULT_LIMIT => 10))
    WHERE STATE IN ('EXECUTING', 'SCHEDULED')
  );
  IF (live_app > 0) THEN
    RETURN 'skipped: nfl_app_to_postgres already executing';
  END IF;

  EXECUTE TASK DLT_DB.OPS.dlt_task_nfl_app_to_postgres;
  RETURN 'fired';
END;
$$;

GRANT USAGE ON PROCEDURE DLT_DB.OPS.SP_APP_COPY_FIRE() TO ROLE DBT_RUNNER_ROLE;

USE ROLE DBT_RUNNER_ROLE;

-- CREATE OR ALTER on a child fails if the graph root is started. Root first.
ALTER TASK IF EXISTS NFL_PROD_DB.OPS.DBT_BUILD_NFL SUSPEND;
ALTER TASK IF EXISTS NFL_PROD_DB.OPS.DBT_HARVEST_NFL SUSPEND;
ALTER TASK IF EXISTS NFL_PROD_DB.OPS.APP_COPY_NFL SUSPEND;

CREATE OR ALTER TASK NFL_PROD_DB.OPS.APP_COPY_NFL
  WAREHOUSE = DBT_WH
  USER_TASK_TIMEOUT_MS = 1800000
  COMMENT = 'Fire nfl_app_to_postgres after harvest unless a postgres copy is already running.'
  AFTER NFL_PROD_DB.OPS.DBT_HARVEST_NFL
AS
  CALL DLT_DB.OPS.SP_APP_COPY_FIRE();

ALTER TASK NFL_PROD_DB.OPS.APP_COPY_NFL SET TAG DLT_DB.OPS.COST_CENTER = 'ingestion';

-- Children before parents. CREATE OR ALTER left them suspended.
ALTER TASK NFL_PROD_DB.OPS.APP_COPY_NFL RESUME;
ALTER TASK NFL_PROD_DB.OPS.DBT_HARVEST_NFL RESUME;
ALTER TASK NFL_PROD_DB.OPS.DBT_BUILD_NFL RESUME;
