-- =============================================================================
-- sources/nfl/07_app_copy_grants.sql
-- Purpose : Let DLT_LOADER_ROLE SELECT the APP marts so nfl_app_to_postgres
--           can read them. APP is owned by DBT_RUNNER_ROLE; the loader only
--           had RAW / OPS / ANALYTICS until this file.
-- Run as  : SYSADMIN
-- Apply   : make setup-source SOURCE=nfl CONFIRM=1
--           (or apply this file alone: snow sql -c weekend-warriors -f ...)
-- =============================================================================

USE ROLE SYSADMIN;

GRANT USAGE ON SCHEMA NFL_PROD_DB.APP TO ROLE DLT_LOADER_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA NFL_PROD_DB.APP TO ROLE DLT_LOADER_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA NFL_PROD_DB.APP TO ROLE DLT_LOADER_ROLE;

-- Watermark reads the latest successful build. DLT_LOADER_ROLE already uses
-- DLT_DB.OPS for _DLT_RUNS; this is the same schema, one more table.
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_BUILDS TO ROLE DLT_LOADER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_BUILDS TO ROLE DLT_DEV_ROLE;
