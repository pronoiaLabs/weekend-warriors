-- =============================================================================
-- sources/postgres/02_external_access.sql
-- Purpose : Allow SPCS jobs to reach the Snowflake Postgres instance.
-- Run as  : ACCOUNTADMIN
-- Apply   : make setup-source SOURCE=postgres CONFIRM=1
--
-- Host only. Do not add 0.0.0.0/0. Laptop access is the instance-level
-- POSTGRES_INGRESS network policy (Snowsight), not this EAI.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE DLT_DB.OPS.POSTGRES_APP_EGRESS
    MODE     = EGRESS
    TYPE     = HOST_PORT
    VALUE_LIST = (
        '3v6glchrerfzlcisoqkcjgkgxm.mcgkxfo-weekend-warriors.us-east-2.aws.postgres.snowflake.app:5432'
    )
    COMMENT  = 'Egress from SPCS to the Weekend Warrior App Postgres instance.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION POSTGRES_APP_EAI
    ALLOWED_NETWORK_RULES = (DLT_DB.OPS.POSTGRES_APP_EGRESS)
    ENABLED = TRUE
    COMMENT = 'External access for dlt jobs writing app.app_copy.';

GRANT USAGE ON INTEGRATION POSTGRES_APP_EAI TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON INTEGRATION POSTGRES_APP_EAI TO ROLE DLT_LOADER_ROLE;
