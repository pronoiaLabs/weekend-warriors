-- =============================================================================
-- base/01_roles.sql
-- Purpose : Create the two functional roles used by the template:
--             * DLT_LOADER_ROLE  -- production loads, deploy/CI, control-plane DML
--             * DLT_DEV_ROLE     -- isolated in-Snowflake development
--           and make both administrable by SYSADMIN.
-- Run as  : USERADMIN (the least-privilege admin for identity objects; owns the
--           roles it creates and can grant them onward). No ACCOUNTADMIN needed.
-- Prerequisites : None -- this is the first script in the sequence.
--
-- Setup order:  base/  ->  then prod/  (production)  and/or  dev/  (development).
-- Both the prod and dev paths depend on these roles + the control-plane objects
-- created in base/02 and base/03.
-- =============================================================================

USE ROLE USERADMIN;

-- ---------------------------------------------------------------------------
-- 1. Production / deploy role
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS DLT_LOADER_ROLE
    COMMENT = 'Production dlt role: scheduled loads into DLT_PROD_DB, deploy/CI, control-plane DML.';

-- ---------------------------------------------------------------------------
-- 2. Development role
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS DLT_DEV_ROLE
    COMMENT = 'Development dlt role: ad-hoc runs into per-developer DLT_DEV_DB schemas.';

-- ---------------------------------------------------------------------------
-- 3. Make both roles administrable by SYSADMIN
-- ---------------------------------------------------------------------------
GRANT ROLE DLT_LOADER_ROLE TO ROLE SYSADMIN;
GRANT ROLE DLT_DEV_ROLE    TO ROLE SYSADMIN;

-- Grant DLT_DEV_ROLE to the developers who will run in-Snowflake dev jobs, e.g.:
--   GRANT ROLE DLT_DEV_ROLE TO USER <developer_login>;
