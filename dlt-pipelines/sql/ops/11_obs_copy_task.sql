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
--           minutes). Both wrappers CALL SP_OBS_COPY_FIRE.
--
--           The from-start latch is not enough on its own: once a
--           replace-load ran longer than the latch window, the next OBS_REFRESH
--           fired a second copy while the first was still INSERT-ing, and
--           Snowflake Postgres OOMed (psycopg2.errors.OutOfMemory, 2026-08-24).
--           nfl_app_to_postgres shares that instance, so overlapping those
--           two is the same failure. The proc therefore also no-ops while
--           either postgres copy is EXECUTING, and for a window after
--           obs_to_postgres last completed (the job's own events would
--           otherwise re-fire it immediately).
--
--           The windows are 50 minutes: with OBS_REFRESH and DBT_RUNS_REFRESH
--           both at a 3600s trigger interval, 50 minutes means the copy runs
--           at most about once an hour even when both graphs fire in the same
--           hour (agreed 2026-08-24). FORCE => TRUE (the dashboard's refresh
--           button) skips the latch and the recency guard but never the two
--           in-flight guards: manual refresh may jump the queue, not stack.
-- Run as  : DLT_LOADER_ROLE (OPERATE + proc + OBS_COPY), then
--           DBT_RUNNER_ROLE (SELECT grants + DBT_OBS_COPY)
-- Apply   : make setup-obs-copy-trigger CONFIRM=1
--           (not setup-ops: the loader Task must exist first)
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

GRANT OPERATE ON TASK DLT_DB.OPS.dlt_task_obs_to_postgres
  TO ROLE DBT_RUNNER_ROLE;
GRANT MONITOR ON TASK DLT_DB.OPS.dlt_task_obs_to_postgres
  TO ROLE DBT_RUNNER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.TASK_RUNS TO ROLE DBT_RUNNER_ROLE;

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

-- Caller's rights: EXECUTE TASK, TASK_HISTORY and the latch DML must run
-- as the caller (the wrapper Task's owner), not as the proc owner.
-- Metadata table functions are blocked in owner's-rights procs.
--
-- Signature change (2026-08-24): the old zero-arg proc must be dropped, or
-- CREATE OR REPLACE of the one-arg form leaves BOTH as overloads and the
-- wrapper Tasks keep calling the stale zero-arg body.
DROP PROCEDURE IF EXISTS DLT_DB.OPS.SP_OBS_COPY_FIRE();

CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_OBS_COPY_FIRE(FORCE BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  -- Both in-flight guards hold even under FORCE: the shared Postgres instance
  -- OOMs when copies overlap, so nothing may ever stack a second copy.
  -- obs_to_postgres_resync is the weekly scheduled full-replace twin.
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

  LET live_obs INTEGER := (
    SELECT COUNT(*)
    FROM TABLE(DLT_DB.INFORMATION_SCHEMA.TASK_HISTORY(
      TASK_NAME => 'DLT_TASK_OBS_TO_POSTGRES', RESULT_LIMIT => 10))
    WHERE STATE IN ('EXECUTING', 'SCHEDULED')
  );
  IF (live_obs > 0) THEN
    RETURN 'skipped: obs_to_postgres already executing';
  END IF;

  IF (NOT FORCE) THEN
    LET just_finished INTEGER := (
      SELECT COUNT(*)
      FROM TABLE(DLT_DB.INFORMATION_SCHEMA.TASK_HISTORY(
        TASK_NAME => 'DLT_TASK_OBS_TO_POSTGRES', RESULT_LIMIT => 10))
      WHERE STATE IN ('SUCCEEDED', 'FAILED')
        AND COMPLETED_TIME > DATEADD('minute', -50, CURRENT_TIMESTAMP())
    );
    IF (just_finished > 0) THEN
      RETURN 'skipped: obs_to_postgres finished within 50 minutes';
    END IF;

    LET recent INTEGER := (
      SELECT COUNT(*)
      FROM DLT_DB.OPS.OBS_COPY_LATCH
      WHERE NAME = 'obs_to_postgres'
        AND LAST_FIRED_AT > DATEADD('minute', -50, CURRENT_TIMESTAMP())
    );
    IF (recent > 0) THEN
      RETURN 'skipped: fired within 50 minutes';
    END IF;
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

GRANT USAGE ON PROCEDURE DLT_DB.OPS.SP_OBS_COPY_FIRE(BOOLEAN) TO ROLE DBT_RUNNER_ROLE;

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
