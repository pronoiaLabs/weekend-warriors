-- =============================================================================
-- ops/11_obs_copy_task.sql
-- Purpose : After OBS_REFRESH and after DBT_RUNS_REFRESH, fire
--           DLT_DB.OPS.dlt_task_obs_to_postgres. Both predecessors live in
--           DLT_DB.OPS, but they do not share an owner: OBS_REFRESH is
--           DLT_LOADER_ROLE, DBT_RUNS_REFRESH is DBT_RUNNER_ROLE. A task
--           graph must share one owner (091405, measured 2026-08-23), so
--           each wrapper sits next to its own root. generate_tasks.py does
--           not emit AFTER.
--
--           The copy job is itself an SPCS container: its logs land in
--           DLT_EVENTS and re-fire OBS_REFRESH. Without a latch that is an
--           infinite loop (measured 2026-08-23: five FAILED fires in four
--           minutes). Both wrappers CALL SP_OBS_COPY_FIRE, which no-ops if
--           a fire started in the last 10 minutes.
-- Run as  : DLT_LOADER_ROLE (OPERATE + proc + OBS_COPY), then
--           DBT_RUNNER_ROLE (SELECT grants + DBT_OBS_COPY)
-- Apply   : make setup-obs-copy-trigger CONFIRM=1
--           (not setup-ops: the loader Task must exist first)
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

GRANT OPERATE ON TASK DLT_DB.OPS.dlt_task_obs_to_postgres
  TO ROLE DBT_RUNNER_ROLE;

-- DBT_* tables are owned by DBT_RUNNER_ROLE. Laptop SYSADMIN can SELECT
-- them; the container cannot. DBT_BUILDS is already granted in
-- sources/nfl/07_app_copy_grants.sql and ops/10.
USE ROLE DBT_RUNNER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_RUNS TO ROLE DLT_LOADER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_RUNS_REFRESH_LOG TO ROLE DLT_LOADER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_QUERY_LOG TO ROLE DLT_LOADER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS TO ROLE DLT_LOADER_ROLE;

USE ROLE DLT_LOADER_ROLE;

CREATE TABLE IF NOT EXISTS DLT_DB.OPS.OBS_COPY_LATCH (
  NAME           VARCHAR PRIMARY KEY,
  LAST_FIRED_AT  TIMESTAMP_LTZ NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON TABLE DLT_DB.OPS.OBS_COPY_LATCH
  TO ROLE DBT_RUNNER_ROLE;

-- Caller's rights: EXECUTE TASK and the latch DML must run as the caller
-- (the wrapper Task's owner), not as the proc owner.
CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_OBS_COPY_FIRE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  LET recent INTEGER := (
    SELECT COUNT(*)
    FROM DLT_DB.OPS.OBS_COPY_LATCH
    WHERE NAME = 'obs_to_postgres'
      AND LAST_FIRED_AT > DATEADD('minute', -10, CURRENT_TIMESTAMP())
  );
  IF (recent > 0) THEN
    RETURN 'skipped: fired within 10 minutes';
  END IF;
  MERGE INTO DLT_DB.OPS.OBS_COPY_LATCH t
  USING (SELECT 'obs_to_postgres' AS NAME, CURRENT_TIMESTAMP() AS LAST_FIRED_AT) s
    ON t.NAME = s.NAME
  WHEN MATCHED THEN UPDATE SET LAST_FIRED_AT = s.LAST_FIRED_AT
  WHEN NOT MATCHED THEN INSERT (NAME, LAST_FIRED_AT) VALUES (s.NAME, s.LAST_FIRED_AT);
  EXECUTE TASK DLT_DB.OPS.dlt_task_obs_to_postgres;
  RETURN 'fired';
END;
$$;

GRANT USAGE ON PROCEDURE DLT_DB.OPS.SP_OBS_COPY_FIRE() TO ROLE DBT_RUNNER_ROLE;

-- Graph 1. Same owner as OBS_REFRESH (DLT_LOADER_ROLE). Root first.
ALTER TASK IF EXISTS DLT_DB.OPS.OBS_REFRESH SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.OBS_COPY SUSPEND;

CREATE OR ALTER TASK DLT_DB.OPS.OBS_COPY
  WAREHOUSE = DLT_OPS_WH
  USER_TASK_TIMEOUT_MS = 600000
  COMMENT = 'Fire obs_to_postgres after OBS_REFRESH. Debounced via SP_OBS_COPY_FIRE.'
  AFTER DLT_DB.OPS.OBS_REFRESH
AS
  CALL DLT_DB.OPS.SP_OBS_COPY_FIRE();

ALTER TASK DLT_DB.OPS.OBS_COPY SET TAG DLT_DB.OPS.COST_CENTER = 'ops';

ALTER TASK DLT_DB.OPS.OBS_COPY RESUME;
ALTER TASK DLT_DB.OPS.OBS_REFRESH RESUME;

-- Graph 2. Same owner as DBT_RUNS_REFRESH (DBT_RUNNER_ROLE).
USE ROLE DBT_RUNNER_ROLE;

ALTER TASK IF EXISTS DLT_DB.OPS.DBT_RUNS_REFRESH SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.DBT_OBS_COPY SUSPEND;

CREATE OR ALTER TASK DLT_DB.OPS.DBT_OBS_COPY
  WAREHOUSE = DLT_OPS_WH
  USER_TASK_TIMEOUT_MS = 600000
  COMMENT = 'Fire obs_to_postgres after DBT_RUNS_REFRESH. Debounced via SP_OBS_COPY_FIRE.'
  AFTER DLT_DB.OPS.DBT_RUNS_REFRESH
AS
  CALL DLT_DB.OPS.SP_OBS_COPY_FIRE();

ALTER TASK DLT_DB.OPS.DBT_OBS_COPY SET TAG DLT_DB.OPS.COST_CENTER = 'ops';

ALTER TASK DLT_DB.OPS.DBT_OBS_COPY RESUME;
ALTER TASK DLT_DB.OPS.DBT_RUNS_REFRESH RESUME;
