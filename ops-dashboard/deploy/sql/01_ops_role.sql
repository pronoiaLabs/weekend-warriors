-- =============================================================================
-- ops-dashboard/deploy/sql/01_ops_role.sql
-- Purpose : OPS_DASHBOARD_ROLE, the role that OWNS the dashboard service.
-- Run as  : starts as USERADMIN, escalates per statement; apply by hand via
--           `make setup CONFIRM=1` from ops-dashboard/. Not in any CI filter,
--           deliberately, same as every other sql/ directory in this repo.
--
-- WHY A DEDICATED ROLE, STATED BLUNTLY
--   Snowflake ingress authenticates WHO is knocking, but every request the
--   container makes runs as the SERVICE OWNER ROLE, not as the viewer. A
--   service owned by DLT_LOADER_ROLE would hand any person with endpoint
--   access a role that owns production Tasks and can write NFL_PROD_DB.RAW.
--   So the dashboard's owner role holds SELECT plus exactly one write-shaped
--   capability: the manual-refresh valve (POST /api/refresh), which CALLs the
--   guarded ops refresh procs and may fire the obs Postgres copy task. The
--   blast radius of the endpoint is read-only observability data plus
--   "refresh the observability data sooner than the hourly schedule would".
--   EXECUTE TASK ON ACCOUNT below sounds broad but is bounded by OPERATE,
--   which this role holds on dlt_task_obs_to_postgres and nothing else.
--
--   Corollary: 03_service.sql must be run AS OPS_DASHBOARD_ROLE. Creating the
--   service as SYSADMIN by accident makes SYSADMIN the owner, and undoing
--   that requires per-object GRANT OWNERSHIP surgery.
--
-- ADDING A SPORT
--   Run data needs NOTHING per sport: every sport's runs live in
--   DLT_DB.OPS.PIPELINE_RUNS, maintained by SP_OBS_REFRESH, which discovers
--   sports from the registry at run time. The per-sport blocks at the bottom
--   exist only for DBT_TRIGGER_LOADS (the dbt build-detail page); a new sport
--   copies that three-line block and nothing else.
-- =============================================================================

USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS OPS_DASHBOARD_ROLE
    COMMENT = 'Owns the ops-dashboard SPCS service. SELECT-only on observability views.';
GRANT ROLE OPS_DASHBOARD_ROLE TO ROLE SYSADMIN;

USE ROLE SYSADMIN;

-- Control plane: the views, the registry, the spec stage, the image repo.
GRANT USAGE ON DATABASE DLT_DB TO ROLE OPS_DASHBOARD_ROLE;
GRANT USAGE ON SCHEMA DLT_DB.OPS TO ROLE OPS_DASHBOARD_ROLE;
GRANT USAGE ON SCHEMA DLT_DB.DEPLOY TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON VIEW DLT_DB.OPS.V_TASK_RUNS TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON VIEW DLT_DB.OPS.V_LOG_LINES TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON VIEW DLT_DB.OPS.V_METRICS TO ROLE OPS_DASHBOARD_ROLE;
-- The run spine: one table, every sport (SPORT = uppercase registry stem).
GRANT SELECT ON TABLE DLT_DB.OPS.PIPELINE_RUNS TO ROLE OPS_DASHBOARD_ROLE;
-- dbt build observability. These three objects and the per-sport
-- DBT_TRIGGER_LOADS below are owned by DBT_RUNNER_ROLE, which SYSADMIN
-- inherits; granting as any role outside that hierarchy fails.
GRANT SELECT ON VIEW DLT_DB.OPS.V_DBT_RUNS TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_QUERY_LOG TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.PIPELINE_REGISTRY TO ROLE OPS_DASHBOARD_ROLE;
GRANT READ ON STAGE DLT_DB.DEPLOY.SPECS TO ROLE OPS_DASHBOARD_ROLE;
GRANT READ ON IMAGE REPOSITORY DLT_DB.DEPLOY.IMAGES TO ROLE OPS_DASHBOARD_ROLE;

-- The service object itself lives in DLT_DB.DEPLOY beside the job services.
GRANT CREATE SERVICE ON SCHEMA DLT_DB.DEPLOY TO ROLE OPS_DASHBOARD_ROLE;

-- Queries the service runs use the ops warehouse; it is XSMALL with a 60s
-- auto-suspend, created by dlt-pipelines/sql/ops/01_event_table.sql.
GRANT USAGE ON WAREHOUSE DLT_OPS_WH TO ROLE OPS_DASHBOARD_ROLE;

-- Per-sport read access, for DBT_TRIGGER_LOADS only; see header.
GRANT USAGE ON DATABASE NFL_PROD_DB TO ROLE OPS_DASHBOARD_ROLE;
GRANT USAGE ON SCHEMA NFL_PROD_DB.OPS TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON TABLE NFL_PROD_DB.OPS.DBT_TRIGGER_LOADS TO ROLE OPS_DASHBOARD_ROLE;

GRANT USAGE ON DATABASE WNBA_PROD_DB TO ROLE OPS_DASHBOARD_ROLE;
GRANT USAGE ON SCHEMA WNBA_PROD_DB.OPS TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON TABLE WNBA_PROD_DB.OPS.DBT_TRIGGER_LOADS TO ROLE OPS_DASHBOARD_ROLE;

GRANT USAGE ON DATABASE NCAAF_PROD_DB TO ROLE OPS_DASHBOARD_ROLE;
GRANT USAGE ON SCHEMA NCAAF_PROD_DB.OPS TO ROLE OPS_DASHBOARD_ROLE;
GRANT SELECT ON TABLE NCAAF_PROD_DB.OPS.DBT_TRIGGER_LOADS TO ROLE OPS_DASHBOARD_ROLE;

-- ---------------------------------------------------------------------------
-- The manual-refresh valve (api/app/routers/refresh.py). The refresh cadence
-- is hourly (OBS_REFRESH / DBT_RUNS_REFRESH at a 3600s trigger interval), and
-- the button is the "I need it now" path: it CALLs the guarded sweep procs
-- and SP_OBS_COPY_FIRE(TRUE). All three procs are EXECUTE AS CALLER, and the
-- service session runs USE SECONDARY ROLES NONE, so every privilege below
-- must be granted DIRECTLY to this role -- no inheritance path applies.
--
-- The grant on SP_OBS_COPY_FIRE(BOOLEAN) itself is NOT here: it lives in
-- dlt-pipelines/sql/ops/11_obs_copy_task.sql beside the proc, because that
-- file DROPs and recreates the proc and a grant living anywhere else would
-- silently vanish on every reapply.
-- ---------------------------------------------------------------------------
-- SYSADMIN inherits both owners (DLT_LOADER_ROLE owns SP_OBS_SWEEP, the copy
-- task and the latch; DBT_RUNNER_ROLE owns SP_DBT_RUNS_SWEEP).
GRANT USAGE ON PROCEDURE DLT_DB.OPS.SP_OBS_SWEEP() TO ROLE OPS_DASHBOARD_ROLE;
GRANT USAGE ON PROCEDURE DLT_DB.OPS.SP_DBT_RUNS_SWEEP() TO ROLE OPS_DASHBOARD_ROLE;
-- OPERATE lets the caller's-rights proc EXECUTE TASK it; MONITOR lets the
-- proc's in-flight guards read TASK_HISTORY for it.
GRANT MONITOR, OPERATE ON TASK DLT_DB.OPS.dlt_task_obs_to_postgres TO ROLE OPS_DASHBOARD_ROLE;
-- The proc MERGEs the debounce latch as the caller.
GRANT SELECT, INSERT, UPDATE ON TABLE DLT_DB.OPS.OBS_COPY_LATCH TO ROLE OPS_DASHBOARD_ROLE;

-- Account-level privileges require ACCOUNTADMIN; these are the only
-- statements that need it.
USE ROLE ACCOUNTADMIN;
-- A public endpoint requires this on the CREATING role.
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE OPS_DASHBOARD_ROLE;
-- EXECUTE TASK is account-level by design in Snowflake; which tasks the role
-- can actually run stays bounded by OPERATE (granted above on exactly one).
-- DLT_LOADER_ROLE and DBT_RUNNER_ROLE already hold this same privilege.
GRANT EXECUTE TASK ON ACCOUNT TO ROLE OPS_DASHBOARD_ROLE;
