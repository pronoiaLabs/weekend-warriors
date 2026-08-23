-- =============================================================================
-- analytics-dashboard/deploy/sql/02_cost_tag.sql
-- Purpose : Cost attribution for the analytics dashboard.
-- Run as  : SYSADMIN, by hand via `make setup CONFIRM=1`.
--
-- The dashboard has no warehouse, pool or task of its own in v1: every query
-- it issues runs on DLT_OPS_WH, which is already tagged COST_CENTER = 'ops'
-- by dlt-pipelines/sql/ops/08_cost_tags.sql. Its spend is therefore visible
-- today under the ops bucket, separated from ingestion and dbt, but not from
-- the ops dashboard.
--
-- Every query this app runs carries a JSON QUERY_TAG
-- ({"app":"analytics-dashboard","sport":...,"tile":...}) set by api/app/db.py,
-- which is the per-app and per-sport breakdown. Read it with TRY_PARSE_JSON
-- on QUERY_HISTORY, never string-match it, the same rule as the dbt tags.
--
-- When the dashboard gets its own warehouse, tag it here:
--   ALTER WAREHOUSE ANALYTICS_WH SET TAG DLT_DB.OPS.COST_CENTER = 'analytics';
-- =============================================================================

USE ROLE SYSADMIN;

-- Nothing to tag in v1; kept so the setup target applies a complete, ordered
-- set of files and a future warehouse has a home. Harmless to re-run.
SELECT 'analytics-dashboard: no dedicated compute in v1, spend rides DLT_OPS_WH (ops)' AS note;
