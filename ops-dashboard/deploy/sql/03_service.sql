-- =============================================================================
-- ops-dashboard/deploy/sql/03_service.sql
-- Purpose : Create the dashboard service and grant endpoint access.
-- Run as  : OPS_DASHBOARD_ROLE. NOT SYSADMIN. The service owner role is what
--           every request executes as; see 01_ops_role.sql for why.
-- Prereqs : 01 and 02 applied; the spec template uploaded (`make spec-upload`);
--           the image pushed (`make image-push`, which tags with the git SHA).
--
-- This file is a template for the first deploy: `make setup CONFIRM=1` renders
-- <GIT_SHA> from TAG (default: current short SHA) into deploy/sql/.generated/
-- and applies the render. Day-to-day upgrades go through
-- `make deploy TAG=<sha>`, which runs the same statement via ALTER.
-- =============================================================================

USE ROLE OPS_DASHBOARD_ROLE;

CREATE SERVICE IF NOT EXISTS DLT_DB.DEPLOY.OPS_DASHBOARD
    IN COMPUTE POOL OPS_DASHBOARD_POOL
    FROM @DLT_DB.DEPLOY.SPECS
    SPECIFICATION_TEMPLATE_FILE = 'ops_dashboard.tmpl.yaml'
    USING (tag => '<GIT_SHA>')
    MIN_INSTANCES = 1
    MAX_INSTANCES = 1
    QUERY_WAREHOUSE = DLT_OPS_WH
    COMMENT = 'Observability dashboard over the DLT_DB.OPS views.';

-- Who may open the page. Ingress sends viewers through Snowflake sign-in and
-- admits anyone holding a role with endpoint usage on this service. Grant the
-- service role to whichever account roles should see the dashboard; every
-- request still executes as OPS_DASHBOARD_ROLE regardless of who is viewing.
GRANT SERVICE ROLE DLT_DB.DEPLOY.OPS_DASHBOARD!ALL_ENDPOINTS_USAGE TO ROLE SYSADMIN;

-- The ingress URL appears once the service is READY (a minute or two on a
-- cold pool):
--   SHOW ENDPOINTS IN SERVICE DLT_DB.DEPLOY.OPS_DASHBOARD;
