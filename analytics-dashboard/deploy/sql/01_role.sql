-- =============================================================================
-- analytics-dashboard/deploy/sql/01_role.sql
-- Purpose : ANALYTICS_DASHBOARD_ROLE, the read-only role the analytics
--           dashboard queries as. SELECT on the semantic views and nothing else.
-- Run as  : starts as USERADMIN, escalates per statement; apply by hand via
--           `make setup CONFIRM=1` from analytics-dashboard/. Not in any CI
--           filter, deliberately, same as every other sql/ directory here.
--
-- WHY ONLY THE SEMANTIC VIEWS
--   Querying a semantic view needs SELECT on the view alone; no privilege on
--   the CORE, PREP or RAW objects beneath it. So the dashboard's blast radius
--   is exactly the seven NFL and four NCAAF views the Cortex agents already
--   expose, and a future view in either ANALYTICS schema is picked up by the
--   FUTURE grant without another run of this file.
--
-- WHY NOT OPS_DASHBOARD_ROLE
--   That role owns an SPCS service and holds observability grants; hanging
--   sport data off it would mix two audiences and two blast radii. The two
--   dashboards are separate apps on separate origins; their roles match.
--
-- ADDING A SPORT
--   Copy the three-line database block at the bottom. Nothing else changes.
-- =============================================================================

USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS ANALYTICS_DASHBOARD_ROLE
    COMMENT = 'Read-only role for the analytics dashboard. SELECT on semantic views only.';
GRANT ROLE ANALYTICS_DASHBOARD_ROLE TO ROLE SYSADMIN;

USE ROLE SYSADMIN;

-- Queries run on the ops warehouse for v1: XSMALL, 60s auto-suspend, already
-- tagged COST_CENTER = 'ops' (dlt-pipelines/sql/ops/08_cost_tags.sql). A
-- dedicated warehouse is a one-line change here if the spend ever warrants it.
GRANT USAGE ON WAREHOUSE DLT_OPS_WH TO ROLE ANALYTICS_DASHBOARD_ROLE;

-- NFL
GRANT USAGE ON DATABASE NFL_PROD_DB TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT USAGE ON SCHEMA NFL_PROD_DB.ANALYTICS TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON ALL SEMANTIC VIEWS IN SCHEMA NFL_PROD_DB.ANALYTICS TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA NFL_PROD_DB.ANALYTICS TO ROLE ANALYTICS_DASHBOARD_ROLE;

-- NCAAF
GRANT USAGE ON DATABASE NCAAF_PROD_DB TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT USAGE ON SCHEMA NCAAF_PROD_DB.ANALYTICS TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON ALL SEMANTIC VIEWS IN SCHEMA NCAAF_PROD_DB.ANALYTICS TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA NCAAF_PROD_DB.ANALYTICS TO ROLE ANALYTICS_DASHBOARD_ROLE;

-- The developer runs the app locally as this role through the `weekend-warriors`
-- connection with ANALYTICS_DASHBOARD_ROLE applied on connect. Granting the
-- role to the connection's user is what makes USE ROLE succeed; the user name
-- lives in ~/.snowflake/connections.toml, not here.
SET analytics_dashboard_user = CURRENT_USER();
GRANT ROLE ANALYTICS_DASHBOARD_ROLE TO USER IDENTIFIER($analytics_dashboard_user);
