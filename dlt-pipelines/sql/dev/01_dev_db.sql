-- =============================================================================
-- dev/01_dev_db.sql
-- Purpose : Create the DEVELOPMENT data database DLT_DEV_DB and grant DLT_DEV_ROLE
--           the ability to create per-developer dataset schemas on demand. Dev
--           runs land in an isolated schema (e.g. DEV_TONY) chosen via the
--           DLT_DATASET env var, so developers never collide with prod or each
--           other. Run metadata is recorded in DLT_DEV_DB.OPS._DLT_RUNS.
-- Run as  : SYSADMIN (owns DLT_DEV_DB and grants below).
-- Prerequisites : base/01_roles.sql, base/02_control_plane.sql, base/03_registry.sql.
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. Development database
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS DLT_DEV_DB
    COMMENT = 'Development data for dlt pipelines (ad-hoc, per-developer schemas).';

-- OPS : per-environment run metadata (_DLT_RUNS is written here by dev runs).
CREATE SCHEMA IF NOT EXISTS DLT_DEV_DB.OPS
    COMMENT = 'Development run metadata: _DLT_RUNS.';

-- ---------------------------------------------------------------------------
-- 2. Grants to DLT_DEV_ROLE
-- ---------------------------------------------------------------------------
GRANT USAGE ON DATABASE DLT_DEV_DB TO ROLE DLT_DEV_ROLE;

-- CREATE SCHEMA lets dlt auto-create a per-developer dataset schema (DEV_<user>)
-- on the first run -- this is what makes each developer's test env isolated.
GRANT CREATE SCHEMA ON DATABASE DLT_DEV_DB TO ROLE DLT_DEV_ROLE;

-- Future grants: any schema DLT_DEV_ROLE creates in DLT_DEV_DB is owned by it,
-- so table/view/stage creation inside DEV_<user> is implicit. The explicit
-- grants below cover the pre-created OPS schema (owned by SYSADMIN).
GRANT USAGE        ON SCHEMA DLT_DEV_DB.OPS TO ROLE DLT_DEV_ROLE;
GRANT CREATE TABLE ON SCHEMA DLT_DEV_DB.OPS TO ROLE DLT_DEV_ROLE;
GRANT CREATE VIEW  ON SCHEMA DLT_DEV_DB.OPS TO ROLE DLT_DEV_ROLE;
GRANT CREATE STAGE ON SCHEMA DLT_DEV_DB.OPS TO ROLE DLT_DEV_ROLE;

-- Cleanup reminder: drop a developer's sandbox schema when done, e.g.
--   DROP SCHEMA IF EXISTS DLT_DEV_DB.DEV_TONY;
