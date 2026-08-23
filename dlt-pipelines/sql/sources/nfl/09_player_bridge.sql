-- =============================================================================
-- 09_player_bridge.sql (nfl) -- account objects behind the player id bridge
-- =============================================================================
-- The bridge maps BallDontLie and Sleeper player ids onto nflverse gsis_id.
-- The matching itself is a Snowpark procedure, DLT_DB.DEPLOY.SP_PLAYER_BRIDGE,
-- whose code lives in dbt-pipelines/snowpark/player_bridge/ and is deployed by
-- `make -C dbt-pipelines deploy-snowpark` (snow snowpark deploy generates the
-- CREATE PROCEDURE; it is the one object this file does not create). dbt calls
-- the procedure from a pre_hook on models/nfl/core/bridges/bridge_player_ids.
--
-- This file creates everything that procedure needs and that is not its own
-- code: the stage its zip lands on, the privilege to create it, Cortex access
-- for the roles that call it, and the Cortex Search service it queries.
--
-- Cost model, so nobody is surprised:
--   * The search service indexes RAW.NFLVERSE_PLAYERS (25k rows, a few MB).
--     It refreshes on TARGET_LAG and auto-suspends after 30 minutes idle;
--     suspended it costs only the index's storage.
--   * The procedure queries it with CORTEX_SEARCH_BATCH, which runs against a
--     suspended service (it spins its own resources) and bills per GB-hour
--     of index for the job plus the query-embedding tokens. One full refresh
--     is one job; the steady state is zero jobs, because the procedure returns
--     before querying when no new player exists. AI_FILTER confirmations are
--     per prompt, a few thousand short ones per full refresh.
--   * Watch: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_BATCH_QUERY_USAGE_HISTORY,
--     CORTEX_SEARCH_SERVING_USAGE_HISTORY, CORTEX_FUNCTIONS_USAGE_HISTORY.
--
-- Kill switch: ALTER CORTEX SEARCH SERVICE NFL_PROD_DB.CORE.PLAYER_SEARCH SUSPEND;
-- (the procedure's deterministic tiers keep working; the search and AI tiers
-- fail inside the procedure, which fails the dbt model, which is the signal.)
--
-- Roles: SYSADMIN for stage and grants, ACCOUNTADMIN for the Cortex database
-- role, DLT_LOADER_ROLE for change tracking on its own table, DBT_RUNNER_ROLE
-- for the service (it owns CORE and the bridge tables land beside it).
--
-- Apply with make setup-source SOURCE=nfl CONFIRM=1.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: the procedure's home (control plane) and who may call Cortex
-- -----------------------------------------------------------------------------

USE ROLE SYSADMIN;

-- snow snowpark deploy uploads the zipped source here and points the
-- procedure's IMPORTS at it. Beside DLT_DB.DEPLOY.SPECS on purpose: one
-- schema holds every deployable artifact.
CREATE STAGE IF NOT EXISTS DLT_DB.DEPLOY.SNOWPARK
  COMMENT = 'Snowpark procedure artifacts (dbt-pipelines/snowpark/). Written by snow snowpark deploy.';

-- CI deploys as DBT_RUNNER_ROLE (deploy.yml dbt job), the laptop as SYSADMIN;
-- both must be able to write the stage and (re)create the procedure.
GRANT READ, WRITE ON STAGE DLT_DB.DEPLOY.SNOWPARK TO ROLE DBT_RUNNER_ROLE;
GRANT CREATE PROCEDURE ON SCHEMA DLT_DB.DEPLOY TO ROLE DBT_RUNNER_ROLE;

-- CORTEX_SEARCH_BATCH and AI_FILTER need the Cortex database role on the
-- CALLING role: the procedure is caller's rights, so the prod trigger task
-- (DBT_RUNNER_ROLE, primary role alone) and dev callers both need it.
USE ROLE ACCOUNTADMIN;

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE DBT_RUNNER_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE DLT_DEV_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SYSADMIN;

-- -----------------------------------------------------------------------------
-- Section 2: the search index over nflverse players
-- -----------------------------------------------------------------------------

-- Incremental index refresh needs change tracking on the base table, and only
-- the owner can set it. dlt reloads this table weekly with truncate-and-insert
-- (its default replace strategy), which keeps the table object and this flag.
USE ROLE DLT_LOADER_ROLE;

ALTER TABLE NFL_PROD_DB.RAW.NFLVERSE_PLAYERS SET CHANGE_TRACKING = TRUE;

-- DBT_RUNNER_ROLE owns CORE (05_dbt_trigger.sql transferred it), so it can
-- create the service there without a further grant. One service serves dev
-- and prod: both read the same prod RAW table, and the bridge tables are
-- written wherever the caller's dbt target points.
USE ROLE DBT_RUNNER_ROLE;

-- POS_GROUP below MUST stay identical to POSITION_GROUPS in
-- dbt-pipelines/snowpark/player_bridge/src/player_bridge/evidence.py and to
-- macros/nfl/nfl_helpers.sql::nfl_position_group: the procedure filters the
-- search on this attribute with the Python side's value.
CREATE CORTEX SEARCH SERVICE IF NOT EXISTS NFL_PROD_DB.CORE.PLAYER_SEARCH
  ON SEARCH_TEXT
  ATTRIBUTES LATEST_TEAM, POS_GROUP
  WAREHOUSE = DBT_WH
  TARGET_LAG = '1 day'
  AUTO_SUSPEND = 1800
  COMMENT = 'Hybrid search over RAW.NFLVERSE_PLAYERS for SP_PLAYER_BRIDGE (batch mode). Suspended between refreshes.'
AS
SELECT
    GSIS_ID,
    ESPN_ID::VARCHAR                                    AS ESPN_ID,
    PFR_ID,
    DISPLAY_NAME,
    POSITION,
    CASE UPPER(POSITION)
        WHEN 'QB' THEN 'QB'
        WHEN 'RB' THEN 'RB' WHEN 'FB' THEN 'RB' WHEN 'HB' THEN 'RB'
        WHEN 'WR' THEN 'WR'
        WHEN 'TE' THEN 'TE'
        WHEN 'OL' THEN 'OL' WHEN 'OT' THEN 'OL' WHEN 'T' THEN 'OL' WHEN 'G' THEN 'OL'
        WHEN 'OG' THEN 'OL' WHEN 'C' THEN 'OL'
        WHEN 'DL' THEN 'DL' WHEN 'DE' THEN 'DL' WHEN 'DT' THEN 'DL' WHEN 'NT' THEN 'DL'
        WHEN 'EDGE' THEN 'DL'
        WHEN 'LB' THEN 'LB' WHEN 'ILB' THEN 'LB' WHEN 'OLB' THEN 'LB' WHEN 'MLB' THEN 'LB'
        WHEN 'WLB' THEN 'LB' WHEN 'SLB' THEN 'LB'
        WHEN 'DB' THEN 'DB' WHEN 'CB' THEN 'DB' WHEN 'S' THEN 'DB' WHEN 'SS' THEN 'DB'
        WHEN 'FS' THEN 'DB' WHEN 'SAF' THEN 'DB' WHEN 'LCB' THEN 'DB' WHEN 'RCB' THEN 'DB'
        WHEN 'K' THEN 'SPEC' WHEN 'PK' THEN 'SPEC' WHEN 'P' THEN 'SPEC' WHEN 'LS' THEN 'SPEC'
        WHEN 'KR' THEN 'SPEC' WHEN 'PR' THEN 'SPEC'
    END                                                 AS POS_GROUP,
    LATEST_TEAM,
    TRY_TO_NUMBER(JERSEY_NUMBER::VARCHAR)::VARCHAR      AS JERSEY_NUMBER,
    COLLEGE_NAME,
    YEAR(TRY_TO_DATE(BIRTH_DATE::VARCHAR))              AS BIRTH_YEAR,   -- lands as VARCHAR
    STATUS,
    ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
        DISPLAY_NAME,
        POSITION,
        LATEST_TEAM,
        IFF(JERSEY_NUMBER IS NULL, NULL, '#' || TRY_TO_NUMBER(JERSEY_NUMBER::VARCHAR)::VARCHAR),
        COLLEGE_NAME
    ), ' ')                                             AS SEARCH_TEXT
FROM NFL_PROD_DB.RAW.NFLVERSE_PLAYERS
WHERE GSIS_ID IS NOT NULL;

-- Dev callers. SYSADMIN inherits DBT_RUNNER_ROLE through the hierarchy and
-- needs nothing; DLT_DEV_ROLE does not.
GRANT USAGE ON CORTEX SEARCH SERVICE NFL_PROD_DB.CORE.PLAYER_SEARCH TO ROLE DLT_DEV_ROLE;
