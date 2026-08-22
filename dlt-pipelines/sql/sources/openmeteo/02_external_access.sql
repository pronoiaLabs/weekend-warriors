-- =============================================================================
-- sources/openmeteo/02_external_access.sql
-- Purpose : Allow SPCS jobs running the `openmeteo` source to reach the three
--           Open-Meteo hosts. A container has no network egress by default.
-- Run as  : ACCOUNTADMIN (network rule + integration), then grant usage.
-- Prerequisites : base/01_roles.sql, base/02_control_plane.sql.
--
-- Applied by: make setup-source SOURCE=openmeteo CONFIRM=1
--
-- There is no 01_databases.sql and no 03_secrets.sql. The source is named for
-- the VENDOR; pipelines are named for the CONTENT (nfl_weather_*) and land in
-- NFL_PROD_DB.RAW, which sources/nfl/01_databases.sql already creates. Open-Meteo
-- has no API key. The `make setup-source` banner will still print
-- "Creates OPENMETEO_DEV_DB"; it derives that from $(SOURCE) and is wrong here.
--
-- The port is REQUIRED in VALUE_LIST; a bare hostname is not enough.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE DLT_DB.OPS.OPENMETEO_API_EGRESS
    MODE     = EGRESS
    TYPE     = HOST_PORT
    VALUE_LIST = (
        'api.open-meteo.com:443',
        'archive-api.open-meteo.com:443',
        'historical-forecast-api.open-meteo.com:443'
    )
    COMMENT  = 'HTTPS egress for the openmeteo source: forecast, ERA5 archive, historical-forecast.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION OPENMETEO_API_EAI
    ALLOWED_NETWORK_RULES = (DLT_DB.OPS.OPENMETEO_API_EGRESS)
    ENABLED = TRUE
    COMMENT = 'External access for dlt SPCS jobs running the openmeteo weather source.';

GRANT USAGE ON INTEGRATION OPENMETEO_API_EAI TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON INTEGRATION OPENMETEO_API_EAI TO ROLE DLT_LOADER_ROLE;
