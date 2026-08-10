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
--   So the dashboard's owner role holds SELECT and nothing else: the blast
--   radius of the endpoint is read-only observability data.
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

-- A public endpoint requires this account-level privilege on the CREATING
-- role. ACCOUNTADMIN is unavoidable here and this is the only statement that
-- needs it.
USE ROLE ACCOUNTADMIN;
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE OPS_DASHBOARD_ROLE;
