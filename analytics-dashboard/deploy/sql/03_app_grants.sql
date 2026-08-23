-- =============================================================================
-- analytics-dashboard/deploy/sql/03_app_grants.sql
-- Purpose : Read access for ANALYTICS_DASHBOARD_ROLE on each sport's APP
--           schema, the dbt-built serving layer the dashboard pages read.
-- Run as  : SYSADMIN (it inherits DBT_RUNNER_ROLE, which owns APP; granting on
--           those objects from outside that hierarchy fails). Apply by hand.
--
-- WHEN TO RUN
--   After the first prod dbt build that creates <SPORT>_PROD_DB.APP. The
--   schema is created by dbt (generate_schema_name), not here: pre-creating it
--   as SYSADMIN would leave the wrong owner and break dbt's CREATE OR REPLACE.
--   Until then the statements below fail with "schema does not exist", which
--   is why this file is separate from 01_role.sql. Idempotent: re-run freely.
--
-- WHY FUTURE GRANTS AND copy_grants BOTH
--   dbt rebuilds every mart with CREATE OR REPLACE. The FUTURE grant covers a
--   brand-new mart the moment it builds; +copy_grants in dbt_project.yml keeps
--   the grant across replacements. Either alone leaves a gap, together they do
--   not.
--
-- ADDING A SPORT
--   Copy one block. Nothing else changes.
-- =============================================================================

USE ROLE SYSADMIN;

-- NFL
GRANT USAGE ON SCHEMA NFL_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA NFL_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA NFL_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA NFL_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA NFL_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;

-- NCAAF
GRANT USAGE ON SCHEMA NCAAF_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA NCAAF_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA NCAAF_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA NCAAF_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA NCAAF_PROD_DB.APP TO ROLE ANALYTICS_DASHBOARD_ROLE;
