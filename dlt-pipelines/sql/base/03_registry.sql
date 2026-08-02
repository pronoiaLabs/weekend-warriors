-- =============================================================================
-- base/03_registry.sql
-- Purpose : Create the control-plane objects that make pipelines config-as-data:
--             1. DLT_DB.OPS.PIPELINE_REGISTRY  -- one row per pipeline
--             2. @DLT_DB.DEPLOY.SPECS          -- stage holding the DEV SPCS job
--                                                 spec templates
--           With these in place, adding a pipeline is an INSERT (via
--           `python -m pipelines.registry_sync`), not an image rebuild.
-- Run as  : SYSADMIN (owns DLT_DB; creates the table + stage and grants on them).
-- Prerequisites : base/01_roles.sql, base/02_control_plane.sql.
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. Control table
-- ---------------------------------------------------------------------------
-- Human source of truth is pipelines/registry.yml in git; registry_sync MERGEs
-- it into this table. The runner (pipelines/run.py) reads this table at
-- execution time when DLT_REGISTRY_SOURCE resolves to "table" (default in SPCS).
-- Read by BOTH prod and dev jobs via the fully-qualified name below, regardless
-- of which data database (DLT_PROD_DB / DLT_DEV_DB) the job loads into.
--
-- Column notes:
--   config            VARIANT  -- source-specific config (the YAML `config` block)
--   target_database   STRING   -- database STEM, not a full name (see below)
--   dataset_name      STRING   -- prod default schema (RAW); dev overrides via the
--                                 DLT_DATASET env var to a per-developer schema.
--   enabled           BOOLEAN  -- FALSE to pause a pipeline without deleting it.
--   pipeline_group    STRING   -- optional grouping for `run.py --group G`
--   write_disposition VARIANT  -- see below.
--
-- WHY target_database HOLDS A STEM, AND WHY IT IS NOT CALLED `database`.
-- The value is 'NFL' or 'DLT', and models.resolve_database() composes the full name
-- as <stem>_<env>_DB: NFL_DEV_DB, NFL_PROD_DB. Storing the resolved name would mean
-- one row per environment, and the whole point of this table is one row per pipeline.
--
-- The column is `target_database` because DATABASE is a keyword. Same reason
-- `pipeline_group` is not called `group`.
--
-- WHY write_disposition IS VARIANT AND NULLABLE, NOT STRING WITH A DEFAULT.
-- It holds one of three things:
--     NULL                                        no pipeline-level override; every
--                                                 resource keeps its own disposition
--     "replace"                                   a plain override applied to all
--                                                 resources in the source
--     {"disposition":"merge","strategy":"scd2"}   the same, in dict form
-- The dict form is how scd2 and other merge strategies are selected, and it cannot
-- fit in a STRING column. NULL is meaningful rather than missing, so there is
-- deliberately no DEFAULT: a default would force an override onto every pipeline,
-- which is the exact behaviour this column shape exists to make optional.
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.PIPELINE_REGISTRY (
    name              STRING            NOT NULL,
    source            STRING            NOT NULL,
    schedule          STRING,
    target_database   STRING            DEFAULT 'DLT',
    dataset_name      STRING            DEFAULT 'RAW',
    write_disposition VARIANT,
    pipeline_group    STRING,
    config            VARIANT,
    enabled           BOOLEAN           DEFAULT TRUE,
    updated_at        TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_pipeline_registry PRIMARY KEY (name)
)
COMMENT = 'Control-plane registry of dlt pipelines. Synced from pipelines/batch/registries/.';

-- ADDING target_database TO AN ACCOUNT THAT ALREADY HAS THE TABLE.
-- The CREATE above is IF NOT EXISTS, so it is a no-op once the table exists and will
-- NOT add a new column. This ALTER is what does it, and it is safe to re-run.
--
-- Existing rows take the DEFAULT of 'DLT', which is the pre-change behaviour: every
-- pipeline loaded into DLT_DEV_DB / DLT_PROD_DB. `make sync-apply` then overwrites
-- each row with the stem from registries/*.yml. Until that sync runs, a container
-- reading this table sends NFL data to the old shared database, so the ALTER and the
-- sync belong in the same sitting.
ALTER TABLE DLT_DB.OPS.PIPELINE_REGISTRY
    ADD COLUMN IF NOT EXISTS target_database STRING DEFAULT 'DLT';

-- MIGRATING AN ACCOUNT CREATED BEFORE write_disposition BECAME VARIANT.
-- The CREATE above is IF NOT EXISTS, so re-running this file will NOT change the
-- column type on an account that already has the table. Snowflake also cannot ALTER
-- a STRING column into a VARIANT. Check first:
--
--     DESC TABLE DLT_DB.OPS.PIPELINE_REGISTRY;
--
-- If write_disposition reads VARCHAR, recreate the table. Nothing is lost: it is a
-- sync target derived from registry.yml, not a source of truth, and `make sync-apply`
-- repopulates it. Change CREATE TABLE IF NOT EXISTS above to CREATE OR REPLACE TABLE
-- for one run, or run that statement manually, then re-sync.

-- ---------------------------------------------------------------------------
-- 2. Spec-template stage
-- ---------------------------------------------------------------------------
-- Holds the DEV SPCS job spec templates, and only those:
--   deploy/spcs/dlt_dev_job.tmpl.yaml           -- ad-hoc dev run, binds a secret
--   deploy/spcs/dlt_dev_job_nosecret.tmpl.yaml  -- ad-hoc dev run, no credential
--
-- NOT the production template. Production Tasks carry their spec INLINE, rendered by
-- deploy/tasks/generate_tasks.py, because Snowflake's server-side template renderer
-- fails inside a Task: it resolves a dependency through
-- snowflake.snowpark.pypi_shared_repository, which the Task's role cannot reach.
-- The dev path is unaffected because it submits interactively.
--
-- Upload with `make dev-spec-upload`, or by hand:
--   PUT file://deploy/spcs/dlt_dev_job.tmpl.yaml @DLT_DB.DEPLOY.SPECS AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
CREATE STAGE IF NOT EXISTS DLT_DB.DEPLOY.SPECS
    DIRECTORY   = (ENABLE = TRUE)
    COMMENT     = 'Dev SPCS job spec templates. Prod Tasks carry their spec inline.';

-- ---------------------------------------------------------------------------
-- 3. Grants
-- ---------------------------------------------------------------------------
-- Runtime read: both prod and dev containers SELECT their spec from the table.
GRANT SELECT ON TABLE DLT_DB.OPS.PIPELINE_REGISTRY TO ROLE DLT_LOADER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.PIPELINE_REGISTRY TO ROLE DLT_DEV_ROLE;
-- registry_sync (run as DLT_LOADER_ROLE from laptop/CI) needs full DML.
GRANT INSERT, UPDATE, DELETE ON TABLE DLT_DB.OPS.PIPELINE_REGISTRY TO ROLE DLT_LOADER_ROLE;

-- EXECUTE JOB SERVICE reads the template file from the stage (both roles).
GRANT READ ON STAGE DLT_DB.DEPLOY.SPECS TO ROLE DLT_LOADER_ROLE;
GRANT READ ON STAGE DLT_DB.DEPLOY.SPECS TO ROLE DLT_DEV_ROLE;
-- Uploading a new template version (PUT) is a deploy-role action.
GRANT WRITE ON STAGE DLT_DB.DEPLOY.SPECS TO ROLE DLT_LOADER_ROLE;
