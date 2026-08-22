-- =============================================================================
-- sources/openmeteo/03_landing.sql
-- Purpose : Empty NFL_PROD_DB.RAW.WEATHER_HOURLY so dbt can source() it before
--           the first Open-Meteo load. deploy-sport of models that read a
--           missing RAW table fails the whole NFL DAG (002003).
-- Run as  : DLT_LOADER_ROLE (CREATE TABLE on RAW). SYSADMIN inherits it.
-- Prerequisites : sources/nfl/01_databases.sql (NFL_PROD_DB.RAW), this source's
--                 02_external_access.sql.
--
-- Applied by: make setup-source SOURCE=openmeteo CONFIRM=1
--
-- IF NOT EXISTS on purpose: re-applying must not wipe a loaded or cloned table.
-- Column list matches what the openmeteo source + dlt emit (see a DEV load's
-- DESCRIBE). dlt MERGEs into this on the first real run.
--
-- Do not clone a person's DEV_<user> schema as the way to introduce a new RAW
-- table. This file is that introduction. Fill it with `make run-prod NAME=…`
-- CONFIRM=1 (or CREATE OR REPLACE … CLONE for a one-time backfill already paid).
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;
USE DATABASE NFL_PROD_DB;
USE SCHEMA RAW;

CREATE TABLE IF NOT EXISTS WEATHER_HOURLY (
    STADIUM_ID     VARCHAR        NOT NULL,
    HOUR_AT        TIMESTAMP_TZ(9) NOT NULL,
    PRODUCT        VARCHAR        NOT NULL,
    TEMPERATURE_F  FLOAT,
    WIND_MPH       FLOAT,
    GUST_MPH       FLOAT,
    WIND_DIR_DEG   NUMBER(19, 0),
    PRECIP_IN      FLOAT,
    WEATHER_CODE   NUMBER(19, 0),
    ELEVATION_M    FLOAT,
    _DLT_LOAD_ID   VARCHAR        NOT NULL,
    _DLT_ID        VARCHAR        NOT NULL
);
