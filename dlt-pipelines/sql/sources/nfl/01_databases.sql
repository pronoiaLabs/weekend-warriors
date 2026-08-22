-- =============================================================================
-- sources/nfl/01_databases.sql
-- Purpose : Storage for ONE sport: NFL_DEV_DB (per-developer sandboxes) and
--           NFL_PROD_DB (scheduled loads into RAW, dbt models into ANALYTICS).
-- Run as  : SYSADMIN (owns the databases and issues the grants below).
-- Prerequisites : base/01_roles.sql (DLT_DEV_ROLE, DLT_LOADER_ROLE),
--                 base/02_control_plane.sql (DLT_DB).
-- Apply   : make setup-source SOURCE=nfl CONFIRM=1
--
-- ADDING A SOURCE: run `make new-source NAME=<name>`, which scaffolds this file,
-- the external access integration and the secret, plus a registry stub with the
-- three wired together. Nothing else is per-source: roles, compute pools,
-- warehouses, the control plane, the image and the spec templates are all shared.
--
-- WHY ONE DATABASE PER SPORT PER ENVIRONMENT
--   The database is the axis Snowflake makes cheapest to grant, clone, replicate,
--   share and drop. Putting sport there means an NFL consumer can be given NFL and
--   nothing else, and a sport can be archived by dropping two objects.
--
--   Crossing it with environment rather than putting environment in the schema is
--   what makes the dev/prod boundary structural: DLT_DEV_ROLE holds no grant on
--   NFL_PROD_DB at all, so a mis-set dataset in a dev run cannot reach production
--   data. A schema-level split would leave that boundary resting on a single grant.
--
-- WHICH SCHEMA A LOAD LANDS IN
--   The registry says `database: NFL` and `dataset_name: RAW`. Prod uses both as-is,
--   giving NFL_PROD_DB.RAW. Dev overrides the schema via DLT_DATASET to DEV_<user>,
--   giving NFL_DEV_DB.DEV_JSMITH. One registry entry, both environments.
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. Development database
--
-- Mirrors sql/dev/01_dev_db.sql. Only OPS is pre-created; the per-developer schemas
-- are created on demand by dlt, which is what the CREATE SCHEMA grant below is for.
-- ---------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS NFL_DEV_DB
    COMMENT = 'NFL development data. Per-developer schemas (DEV_<user>), created on demand.';

-- OPS : run metadata. observability.record_run writes _DLT_RUNS here, in whichever
-- database the load targeted, so dev run history stays separate from prod.
CREATE SCHEMA IF NOT EXISTS NFL_DEV_DB.OPS
    COMMENT = 'NFL development run metadata: _DLT_RUNS.';

GRANT USAGE         ON DATABASE NFL_DEV_DB TO ROLE DLT_DEV_ROLE;

-- CREATE SCHEMA is what lets dlt create DEV_<user> and its _STAGING sibling on the
-- first run. Schemas it creates are owned by this role, so table creation inside
-- them needs no further grant.
GRANT CREATE SCHEMA ON DATABASE NFL_DEV_DB TO ROLE DLT_DEV_ROLE;

GRANT USAGE         ON SCHEMA NFL_DEV_DB.OPS TO ROLE DLT_DEV_ROLE;
GRANT CREATE TABLE  ON SCHEMA NFL_DEV_DB.OPS TO ROLE DLT_DEV_ROLE;
GRANT CREATE VIEW   ON SCHEMA NFL_DEV_DB.OPS TO ROLE DLT_DEV_ROLE;
GRANT CREATE STAGE  ON SCHEMA NFL_DEV_DB.OPS TO ROLE DLT_DEV_ROLE;

-- Clean up a developer's sandbox with:
--   DROP SCHEMA IF EXISTS NFL_DEV_DB.DEV_JSMITH;

-- ---------------------------------------------------------------------------
-- 2. Production database
--
-- Mirrors sql/prod/01_prod_db.sql, with one correction noted below.
-- ---------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS NFL_PROD_DB
    COMMENT = 'NFL production data. Scheduled dlt loads into RAW; dbt builds ANALYTICS.';

-- RAW : pipeline-managed landing tables plus dlt's own _dlt_* state tables.
CREATE SCHEMA IF NOT EXISTS NFL_PROD_DB.RAW
    COMMENT = 'Raw / landing layer written by dlt (production).';

-- dbt layers. PREP / CORE / FEATURES / ANALYTICS. Created here so a greenfield
-- `make setup-source SOURCE=nfl` is enough before the first EXECUTE DBT PROJECT:
-- DBT_RUNNER_ROLE has no CREATE SCHEMA on this database. ANALYTICS is not called
-- STAGING, deliberately -- dlt creates <dataset>_STAGING for every merge, so
-- RAW_STAGING already exists and a dbt schema called STAGING would sit beside it
-- meaning something entirely different.
--
-- ML is not a dbt layer. SYSADMIN keeps it (registry, experiments, pred tables).
-- Stage + CREATE MODEL live in 06_ml.sql, which this same setup-source glob applies.
CREATE SCHEMA IF NOT EXISTS NFL_PROD_DB.PREP
    COMMENT = 'dbt staging views over RAW.';
CREATE SCHEMA IF NOT EXISTS NFL_PROD_DB.CORE
    COMMENT = 'dbt conformed dimensions and facts.';
CREATE SCHEMA IF NOT EXISTS NFL_PROD_DB.FEATURES
    COMMENT = 'dbt ML feature marts. Not exposed to Cortex agents.';
CREATE SCHEMA IF NOT EXISTS NFL_PROD_DB.ML
    COMMENT = 'Model registry, experiments, and batch predictions. SYSADMIN-owned, not dbt, not Cortex.';
CREATE SCHEMA IF NOT EXISTS NFL_PROD_DB.ANALYTICS
    COMMENT = 'dbt semantic views and evaluations. Not STAGING: dlt owns RAW_STAGING.';

-- OPS : production run metadata.
CREATE SCHEMA IF NOT EXISTS NFL_PROD_DB.OPS
    COMMENT = 'NFL production run metadata: _DLT_RUNS.';

GRANT USAGE ON DATABASE NFL_PROD_DB TO ROLE DLT_LOADER_ROLE;

-- CREATE SCHEMA on the PRODUCTION database, which sql/prod/01_prod_db.sql omits.
--
-- That omission is a real bug, not a tightening: dlt creates <dataset>_STAGING for
-- every merge-disposition load, and every NFL pipeline merges. Without this grant the
-- first scheduled run fails trying to create RAW_STAGING. Dev has always worked only
-- because sql/dev/01_dev_db.sql does grant it.
GRANT CREATE SCHEMA ON DATABASE NFL_PROD_DB TO ROLE DLT_LOADER_ROLE;

GRANT USAGE        ON SCHEMA NFL_PROD_DB.RAW TO ROLE DLT_LOADER_ROLE;
GRANT CREATE TABLE ON SCHEMA NFL_PROD_DB.RAW TO ROLE DLT_LOADER_ROLE;
GRANT CREATE VIEW  ON SCHEMA NFL_PROD_DB.RAW TO ROLE DLT_LOADER_ROLE;
GRANT CREATE STAGE ON SCHEMA NFL_PROD_DB.RAW TO ROLE DLT_LOADER_ROLE;

GRANT USAGE        ON SCHEMA NFL_PROD_DB.OPS TO ROLE DLT_LOADER_ROLE;
GRANT CREATE TABLE ON SCHEMA NFL_PROD_DB.OPS TO ROLE DLT_LOADER_ROLE;
GRANT CREATE VIEW  ON SCHEMA NFL_PROD_DB.OPS TO ROLE DLT_LOADER_ROLE;
GRANT CREATE STAGE ON SCHEMA NFL_PROD_DB.OPS TO ROLE DLT_LOADER_ROLE;

-- ANALYTICS is granted read-only to the loader: dlt has no business writing there.
-- dbt writes it under its own role, which this file does not create because the dbt
-- project is not wired up yet (see dbt-pipelines/env.yml).
GRANT USAGE ON SCHEMA NFL_PROD_DB.ANALYTICS TO ROLE DLT_LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- 3. What is deliberately NOT granted
--
-- DLT_DEV_ROLE gets nothing on NFL_PROD_DB, and DLT_LOADER_ROLE gets nothing on
-- NFL_DEV_DB. That is the whole point of crossing sport with environment: the
-- separation is a missing grant on a different database, not a convention about
-- schema names, so no run-time mistake can cross it.
-- ---------------------------------------------------------------------------
