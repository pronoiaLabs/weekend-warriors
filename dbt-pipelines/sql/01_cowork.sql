-- =============================================================================
-- sql/01_cowork.sql
-- =============================================================================
-- Purpose       : One-time Snowflake CoWork setup: create the account's CoWork
--                 object and register the prod analyst agents in it, so they
--                 are usable from the CoWork chat surface as well as the
--                 Agents page.
-- Run as        : ACCOUNTADMIN (object creation + grants), then SYSADMIN
--                 holds MODIFY for all future agent add/remove.
-- Prerequisites : The NFL and NCAAF prod agents exist.
-- Apply         : snow sql -c weekend-warriors -f dbt-pipelines/sql/01_cowork.sql
--
-- NAMING DECODER: "Snowflake CoWork" is the product name; the SQL object type
-- is SNOWFLAKE INTELLIGENCE (the feature's earlier name). The Snowsight
-- "Add to Snowflake CoWork" button is exactly ALTER ... ADD AGENT on this
-- object, and the MODIFY privilege it complains about is MODIFY on this
-- object, held only by ACCOUNTADMIN until granted out.
--
-- COST: CoWork usage bills at the same Credit Consumption Table 6(d) rates
-- as Cortex Agents (the agents' orchestration model applies), so adding
-- agents here changes where they can be used, not what a question costs.
--
-- ADDING A SPORT LATER: one ALTER ... ADD AGENT line per new prod agent,
-- runnable as SYSADMIN thanks to the MODIFY grant below.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- The name Snowsight would auto-create on first settings edit; created
-- explicitly so this file is the record of where it came from.
CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

-- SYSADMIN manages agent membership from here on; ACCOUNTADMIN is only
-- needed for this file.
GRANT MODIFY ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE SYSADMIN;

-- Visibility of the CoWork surface. PUBLIC is fine for a single-user
-- account; tighten to a named role before adding teammates.
GRANT USAGE ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE PUBLIC;

-- -----------------------------------------------------------------------------
-- Register the prod agents. Dev copies (DEV_<user> schemas) stay out: they
-- are per-developer scratch agents and lag prod by design.
-- -----------------------------------------------------------------------------

USE ROLE SYSADMIN;

ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT NFL_PROD_DB.ANALYTICS.NFL_ANALYST;

-- The NFL discipline roster (nfl_analyst stays the general fallback).
-- ADD AGENT errors on an already-registered agent, so on an account where
-- the lines above have run, apply only the statements that are new.
ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT NFL_PROD_DB.ANALYTICS.NFL_TEAM_FORM_ANALYST;

ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT NFL_PROD_DB.ANALYTICS.NFL_PLAYER_ANALYST;

ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT NFL_PROD_DB.ANALYTICS.NFL_SITUATION_ANALYST;

ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT NFL_PROD_DB.ANALYTICS.NFL_AVAILABILITY_ANALYST;

ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT NFL_PROD_DB.ANALYTICS.NFL_MARKET_ANALYST;

ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT NCAAF_PROD_DB.ANALYTICS.NCAAF_ANALYST;
