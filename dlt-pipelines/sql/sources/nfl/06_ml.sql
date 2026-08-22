-- =============================================================================
-- sources/nfl/06_ml.sql
-- Purpose : Registry / prediction objects for NFL models. Not dbt. Not Cortex.
--           Schema itself is created in 01_databases.sql so setup-source is
--           enough on a greenfield account; this file adds the stage and the
--           privileges log_model / run_batch need.
-- Run as  : SYSADMIN.
-- Apply   : make setup-source SOURCE=nfl CONFIRM=1  (or snow sql -f)
--
-- OWNERSHIP stays with SYSADMIN. Do not GRANT OWNERSHIP of ML to
-- DBT_RUNNER_ROLE: that role's CREATE OR REPLACE would collide with registry
-- objects, and scoring must not live inside SP_DBT_BUILD.
-- =============================================================================

USE ROLE SYSADMIN;

CREATE SCHEMA IF NOT EXISTS NFL_PROD_DB.ML
    COMMENT = 'Model registry, experiments, and batch predictions. SYSADMIN-owned, not dbt, not Cortex.';

-- Internal stage for mv.run_batch() Parquet. External stages are not valid
-- batch-inference output. SNOWFLAKE_SSE = server-side encryption.
CREATE STAGE IF NOT EXISTS NFL_PROD_DB.ML.INFERENCE_STAGE
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'Parquet output for Model Registry batch inference (run_batch).';

GRANT USAGE ON SCHEMA NFL_PROD_DB.ML TO ROLE SYSADMIN;
GRANT CREATE TABLE ON SCHEMA NFL_PROD_DB.ML TO ROLE SYSADMIN;
GRANT CREATE STAGE ON SCHEMA NFL_PROD_DB.ML TO ROLE SYSADMIN;
GRANT CREATE VIEW ON SCHEMA NFL_PROD_DB.ML TO ROLE SYSADMIN;
GRANT CREATE MODEL ON SCHEMA NFL_PROD_DB.ML TO ROLE SYSADMIN;

-- Trainer reads FEATURES, never writes it.
GRANT USAGE ON SCHEMA NFL_PROD_DB.FEATURES TO ROLE SYSADMIN;
GRANT SELECT ON ALL TABLES IN SCHEMA NFL_PROD_DB.FEATURES TO ROLE SYSADMIN;
GRANT SELECT ON FUTURE TABLES IN SCHEMA NFL_PROD_DB.FEATURES TO ROLE SYSADMIN;
