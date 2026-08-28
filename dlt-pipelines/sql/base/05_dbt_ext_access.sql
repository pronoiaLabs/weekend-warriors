-- =============================================================================
-- base/05_dbt_ext_access.sql
-- Purpose : External Access Integration for `dbt deps` inside EXECUTE DBT
--           PROJECT: hub.getdbt.com (package index) and codeload.github.com
--           (package downloads). Every `snow dbt deploy` in dbt-pipelines
--           references it (--external-access-integration dbt_ext_access).
-- Run as  : ACCOUNTADMIN (CREATE EXTERNAL ACCESS INTEGRATION), grants after.
-- Prerequisites : base/02_control_plane.sql (DLT_DB.OPS), base/04_dbt_runner.sql
--                 (DBT_RUNNER_ROLE).
-- Apply   : make setup-base CONFIRM=1
--
-- IF NOT EXISTS, not OR REPLACE: replacing an integration DROPS its grants,
-- the same trap the dbt project object and the Snowpark proc already document.
-- On an account where DBT_EXT_ACCESS was created ad hoc (this repo's own: the
-- integration predates this file, on a standalone network rule), the CREATEs
-- no-op and only the grants apply; the DLT_DB.OPS.DBT_HUB_EGRESS rule below is
-- then created but unreferenced, which is harmless.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE NETWORK RULE IF NOT EXISTS DLT_DB.OPS.DBT_HUB_EGRESS
    MODE     = EGRESS
    TYPE     = HOST_PORT
    VALUE_LIST = ('hub.getdbt.com', 'codeload.github.com')
    COMMENT  = 'dbt deps egress: package index + GitHub downloads.';

CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS DBT_EXT_ACCESS
    ALLOWED_NETWORK_RULES = (DLT_DB.OPS.DBT_HUB_EGRESS)
    ENABLED = TRUE
    COMMENT = 'Allows dbt deps to fetch packages from hub.getdbt.com and codeload.github.com.';

-- SYSADMIN deploys interactively from the laptop; DBT_RUNNER_ROLE deploys from
-- CI and runs the triggered prod builds.
GRANT USAGE ON INTEGRATION DBT_EXT_ACCESS TO ROLE SYSADMIN;
GRANT USAGE ON INTEGRATION DBT_EXT_ACCESS TO ROLE DBT_RUNNER_ROLE;
