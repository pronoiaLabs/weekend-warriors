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
    season_rollover_month NUMBER(2,0)   DEFAULT 8,
    secret            STRING,
    env_var           STRING,
    external_access   STRING,
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
-- Existing rows are backfilled to 'DLT', which is the pre-change behaviour: every
-- pipeline loaded into DLT_DEV_DB / DLT_PROD_DB. `make sync-apply` then overwrites
-- each row with the stem from registries/*.yml. Until that sync runs, a container
-- reading this table sends NFL data to the old shared database, so the ALTER and the
-- sync belong in the same sitting.
--
-- WHY THE DEFAULT IS AN UPDATE RATHER THAN A DEFAULT CLAUSE, IN BOTH MIGRATIONS BELOW.
--     `ADD COLUMN IF NOT EXISTS <col> <type>` is a clean no-op when the column is
--     already there. Add `DEFAULT <value>` to it and Snowflake stops honouring the
--     IF NOT EXISTS, raising `ambiguous column name '<COL>'` instead:
--
--         ALTER TABLE t ADD COLUMN IF NOT EXISTS b STRING;              -- no-op, fine
--         ALTER TABLE t ADD COLUMN IF NOT EXISTS b STRING DEFAULT 'x';  -- 002028 error
--
--     So a DEFAULT here makes this file work exactly once per column and fail every run
--     after, which breaks `make setup-base` for the whole account rather than for one
--     statement. The column DEFAULT is not worth that: `registry_sync` binds every
--     column on every MERGE, so nothing ever relies on it. The guarded UPDATE gives the
--     one thing that did matter, backfilling rows that predate the column, and is itself
--     a no-op on re-run. `ALTER COLUMN ... SET DEFAULT` is not an escape hatch either;
--     Snowflake rejects it as an unsupported feature.
ALTER TABLE DLT_DB.OPS.PIPELINE_REGISTRY
    ADD COLUMN IF NOT EXISTS target_database STRING;

UPDATE DLT_DB.OPS.PIPELINE_REGISTRY
    SET target_database = 'DLT'
    WHERE target_database IS NULL;

-- ADDING season_rollover_month TO AN ACCOUNT THAT ALREADY HAS THE TABLE.
-- Same story as target_database above: the CREATE is a no-op once the table exists, so
-- this ALTER is what adds the column, and it is safe to re-run.
--
-- WHY THIS COLUMN EXISTS AT ALL. It feeds the `{current_season}` token, and the month a
-- season starts is per sport: 8 for the NFL, 5 for the WNBA. A container in SPCS reads
-- its spec from THIS TABLE, not from the YAML, so a rollover that lives only in
-- registries/*.yml would be correct on a laptop and silently fall back to the default 8
-- inside every scheduled Task. For the WNBA that means May, June and July resolving to
-- last season while the current one is being played, and the API answers a stale season
-- with data rather than an error.
--
-- Existing rows are backfilled to 8, which is the pre-change behaviour. `make
-- sync-apply` then writes each pipeline's real value from its registry file.
--
-- The backfill is not cosmetic. `spec_from_row` in pipelines/batch/models.py reads this
-- column through `int(...)`, so a NULL is a TypeError rather than a fallback, and a
-- container that fires between this ALTER and the sync would die on it.
ALTER TABLE DLT_DB.OPS.PIPELINE_REGISTRY
    ADD COLUMN IF NOT EXISTS season_rollover_month NUMBER(2,0);

UPDATE DLT_DB.OPS.PIPELINE_REGISTRY
    SET season_rollover_month = 8
    WHERE season_rollover_month IS NULL;

-- ADDING secret / env_var / external_access TO AN ACCOUNT THAT ALREADY HAS THE TABLE.
--
-- WHY THESE THREE ARE COLUMNS AND NOT ONLY YAML. A scheduled pipeline must record the
-- Snowflake SECRET holding its credential, the env var that secret binds to, and the
-- external access integration that gives the container egress. `validate()` refuses a
-- `schedule` without all three, because a Task passes no arguments and the alternative
-- is a container dying at 09:00 UTC with nobody watching.
--
-- generate_tasks.py reads registries/*.yml, so the Task DDL was always correct: the
-- secret was bound and the EAI attached. The container is the problem. It rebuilds its
-- spec from THIS TABLE (DLT_REGISTRY_SOURCE=auto), so with no columns to read it saw
-- None for all three and raised RegistryError from spec_from_row before doing any work.
-- Every scheduled Task failed that way, and the Task DDL looking right is exactly what
-- made it hard to see.
--
-- NO BACKFILL, UNLIKE THE TWO MIGRATIONS ABOVE. There is no sensible account-wide
-- default: the values are per source (DLT_DB.OPS.NFL_API_KEY against
-- DLT_DB.OPS.WNBA_API_KEY, and one EAI per upstream host). Rows stay NULL until
-- `make sync-apply` writes each pipeline's real values, so the ALTER and the sync
-- belong in the same sitting. NULL is also correct and permanent for `sample`, which
-- has no schedule and needs none of them.
ALTER TABLE DLT_DB.OPS.PIPELINE_REGISTRY
    ADD COLUMN IF NOT EXISTS secret STRING;

ALTER TABLE DLT_DB.OPS.PIPELINE_REGISTRY
    ADD COLUMN IF NOT EXISTS env_var STRING;

ALTER TABLE DLT_DB.OPS.PIPELINE_REGISTRY
    ADD COLUMN IF NOT EXISTS external_access STRING;

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
