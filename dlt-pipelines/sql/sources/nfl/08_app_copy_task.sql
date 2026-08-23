-- =============================================================================
-- sources/nfl/08_app_copy_task.sql
-- Purpose : After each NFL harvest, fire DLT_DB.OPS.dlt_task_nfl_app_to_postgres.
--           Snowflake task graphs cannot cross schemas (091413) and must share
--           one owner, so this wrapper lives next to DBT_HARVEST_NFL
--           (NFL_PROD_DB.OPS / DBT_RUNNER_ROLE) and EXECUTE TASKs the loader
--           Task in DLT_DB.OPS. generate_tasks.py does not emit AFTER.
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

USE ROLE DBT_RUNNER_ROLE;

-- CREATE OR ALTER on a child fails if the graph root is started. Root first.
ALTER TASK IF EXISTS NFL_PROD_DB.OPS.DBT_BUILD_NFL SUSPEND;
ALTER TASK IF EXISTS NFL_PROD_DB.OPS.DBT_HARVEST_NFL SUSPEND;
ALTER TASK IF EXISTS NFL_PROD_DB.OPS.APP_COPY_NFL SUSPEND;

CREATE OR ALTER TASK NFL_PROD_DB.OPS.APP_COPY_NFL
  WAREHOUSE = DBT_WH
  USER_TASK_TIMEOUT_MS = 1800000
  COMMENT = 'Fire nfl_app_to_postgres after harvest. Wrapper only; the job lives in DLT_DB.OPS.'
  AFTER NFL_PROD_DB.OPS.DBT_HARVEST_NFL
AS
  EXECUTE TASK DLT_DB.OPS.dlt_task_nfl_app_to_postgres;

ALTER TASK NFL_PROD_DB.OPS.APP_COPY_NFL SET TAG DLT_DB.OPS.COST_CENTER = 'ingestion';

-- Children before parents. CREATE OR ALTER left them suspended.
ALTER TASK NFL_PROD_DB.OPS.APP_COPY_NFL RESUME;
ALTER TASK NFL_PROD_DB.OPS.DBT_HARVEST_NFL RESUME;
ALTER TASK NFL_PROD_DB.OPS.DBT_BUILD_NFL RESUME;
