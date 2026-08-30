-- =============================================================================
-- 04_dbt_runner.sql -- the dbt build identity
-- =============================================================================
-- DBT_RUNNER_ROLE is the least-privilege role that owns the dbt side of prod:
-- the PREP / CORE / FEATURES / ANALYTICS schemas and their contents (transferred in each
-- sport's 05_dbt_trigger.sql), the per-sport dbt trigger tasks, and the
-- warehouse the builds run on. dbt-pipelines/env.yml names it as DBT_ROLE for
-- the prod environments; dev environments keep CURRENT_ROLE().
--
-- Why ownership and not broad grants: dbt materializes with CREATE OR REPLACE,
-- which requires owning the existing object. A role with mere CREATE grants
-- cannot replace another role's table, so the schemas transfer wholesale.
-- SYSADMIN keeps full access through the role hierarchy grant below.
--
-- Verified 2026-08-09 (WORKFLOW-4.md Phase 0):
--   * the privilege that lets a role invoke EXECUTE DBT PROJECT is USAGE on
--     the project object (granted per object in the per-sport files);
--   * no usage on the DBT_EXT_ACCESS integration is needed at execute time
--     (dbt deps are vendored into the project object at deploy time);
--   * EXECUTE TASK ON ACCOUNT is required for the role's warehouse-based
--     triggered tasks to run, mirroring DLT_LOADER_ROLE in 02_control_plane.
--
-- Everything here is idempotent; apply with make setup-base CONFIRM=1.
-- =============================================================================

USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS DBT_RUNNER_ROLE
  COMMENT = 'Least-privilege dbt build identity: owns PREP/CORE/ANALYTICS and the dbt trigger tasks';

USE ROLE SECURITYADMIN;

-- SYSADMIN inherits everything the role owns, so humans keep full access.
GRANT ROLE DBT_RUNNER_ROLE TO ROLE SYSADMIN;

USE ROLE SYSADMIN;

-- No dedicated warehouse anymore: dbt builds run on DLT_WH, the single job
-- warehouse (consolidated 2026-08 -- three XS warehouses waking separately
-- billed mostly 60s resume minimums and auto-suspend tails, measured at ~2/3
-- of daily spend). The grant lives in sql/prod/02_compute.sql next to the
-- warehouse's creation, because this file runs before prod/02 on a fresh
-- account and a grant on a warehouse that does not exist yet fails.
-- Cost separation now comes from dbt QUERY_TAGs and task-level COST_CENTER
-- tags, not warehouse metering. EXECUTE DBT PROJECT cannot run serverless,
-- so a real warehouse is still mandatory.

-- The per-sport dbt project objects live in the control plane's DEPLOY schema
-- (DLT_DB.DEPLOY.CORTEX_LIFECYCLE_<SPORT>); the role needs the path to them.
-- The object-level USAGE grants are in each sport's 05_dbt_trigger.sql.
GRANT USAGE ON DATABASE DLT_DB TO ROLE DBT_RUNNER_ROLE;
GRANT USAGE ON SCHEMA DLT_DB.DEPLOY TO ROLE DBT_RUNNER_ROLE;

-- (USAGE, OPERATE on DLT_WH for this role is granted in prod/02 itself:
-- that warehouse does not exist until prod/02 runs, which is after this file.)

USE ROLE ACCOUNTADMIN;

-- Warehouse-based tasks owned by the role cannot run without this, exactly
-- the DLT_LOADER_ROLE precedent in 02_control_plane.sql.
GRANT EXECUTE TASK ON ACCOUNT TO ROLE DBT_RUNNER_ROLE;
