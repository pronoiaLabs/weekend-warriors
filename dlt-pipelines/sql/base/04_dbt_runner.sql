-- =============================================================================
-- 04_dbt_runner.sql -- the dbt build identity
-- =============================================================================
-- DBT_RUNNER_ROLE is the least-privilege role that owns the dbt side of prod:
-- the PREP / CORE / ANALYTICS schemas and their contents (transferred in each
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

-- Dedicated warehouse: the trigger tasks and every prod EXECUTE DBT PROJECT
-- run here, not on DEVELOPMENT_WH, so scheduled builds never queue behind
-- interactive work and the cost of the trigger machinery reads directly off
-- one warehouse's metering. EXECUTE DBT PROJECT cannot run serverless, so a
-- real warehouse is mandatory.
CREATE WAREHOUSE IF NOT EXISTS DBT_WH
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'dbt builds: trigger tasks and prod EXECUTE DBT PROJECT runs';

GRANT USAGE, OPERATE ON WAREHOUSE DBT_WH TO ROLE DBT_RUNNER_ROLE;

-- The per-sport dbt project objects live in the control plane's DEPLOY schema
-- (DLT_DB.DEPLOY.CORTEX_LIFECYCLE_<SPORT>); the role needs the path to them.
-- The object-level USAGE grants are in each sport's 05_dbt_trigger.sql.
GRANT USAGE ON DATABASE DLT_DB TO ROLE DBT_RUNNER_ROLE;
GRANT USAGE ON SCHEMA DLT_DB.DEPLOY TO ROLE DBT_RUNNER_ROLE;

-- SP_DBT_RUNS_REFRESH (ops/07) discovers the sport list from the registry at
-- run time, which is what makes "a new sport needs zero observability
-- objects" true. Granted here because this file creates the role (base/03
-- runs earlier and cannot). Repeated in ops/07's slice for existing accounts.
GRANT SELECT ON TABLE DLT_DB.OPS.PIPELINE_REGISTRY TO ROLE DBT_RUNNER_ROLE;
-- (USAGE on DLT_OPS_WH for the ops/07 tasks is granted in ops/07 itself:
-- that warehouse does not exist until ops/01 runs, which is after this file.)

USE ROLE ACCOUNTADMIN;

-- Warehouse-based tasks owned by the role cannot run without this, exactly
-- the DLT_LOADER_ROLE precedent in 02_control_plane.sql.
GRANT EXECUTE TASK ON ACCOUNT TO ROLE DBT_RUNNER_ROLE;
