-- =============================================================================
-- prod/01_prod_db.sql
-- Purpose : Create the PRODUCTION data database DLT_PROD_DB and grant the
--           production role write access. Scheduled Tasks load here (dataset
--           RAW); run metadata is recorded in DLT_PROD_DB.OPS._DLT_RUNS.
-- Run as  : SYSADMIN (owns DLT_PROD_DB and grants below).
-- Prerequisites : base/01_roles.sql, base/02_control_plane.sql, base/03_registry.sql.
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. Production database and schemas
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS DLT_PROD_DB
    COMMENT = 'Production data for dlt pipelines (scheduled loads).';

-- RAW : pipeline-managed landing tables and dlt state tables (_dlt_*).
CREATE SCHEMA IF NOT EXISTS DLT_PROD_DB.RAW
    COMMENT = 'Raw / landing layer written by dlt (production).';

-- OPS : per-environment run metadata (_DLT_RUNS is written here by the runner).
CREATE SCHEMA IF NOT EXISTS DLT_PROD_DB.OPS
    COMMENT = 'Production run metadata: _DLT_RUNS.';

-- ---------------------------------------------------------------------------
-- 2. Grants to DLT_LOADER_ROLE (least-privilege)
-- ---------------------------------------------------------------------------
GRANT USAGE ON DATABASE DLT_PROD_DB TO ROLE DLT_LOADER_ROLE;

-- CREATE SCHEMA, which this file omitted until now. dlt creates <dataset>_STAGING for
-- every merge-disposition load, so without this the first scheduled run fails trying
-- to create RAW_STAGING. Dev has always worked only because sql/dev/01_dev_db.sql
-- grants it. sql/sources/<name>/01_databases.sql carries the same grant.
GRANT CREATE SCHEMA ON DATABASE DLT_PROD_DB TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON SCHEMA DLT_PROD_DB.RAW TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON SCHEMA DLT_PROD_DB.OPS TO ROLE DLT_LOADER_ROLE;

-- RAW: dlt creates data tables, views, and internal stages (_dlt_load files).
GRANT CREATE TABLE ON SCHEMA DLT_PROD_DB.RAW TO ROLE DLT_LOADER_ROLE;
GRANT CREATE VIEW  ON SCHEMA DLT_PROD_DB.RAW TO ROLE DLT_LOADER_ROLE;
GRANT CREATE STAGE ON SCHEMA DLT_PROD_DB.RAW TO ROLE DLT_LOADER_ROLE;

-- OPS: dlt creates _DLT_RUNS and any control tables here.
GRANT CREATE TABLE ON SCHEMA DLT_PROD_DB.OPS TO ROLE DLT_LOADER_ROLE;
GRANT CREATE VIEW  ON SCHEMA DLT_PROD_DB.OPS TO ROLE DLT_LOADER_ROLE;
GRANT CREATE STAGE ON SCHEMA DLT_PROD_DB.OPS TO ROLE DLT_LOADER_ROLE;
