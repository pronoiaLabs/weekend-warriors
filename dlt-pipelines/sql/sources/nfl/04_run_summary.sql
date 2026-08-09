-- =============================================================================
-- sources/nfl/04_run_summary.sql
-- Purpose : Retire the per-sport run-summary view. NFL run rows now live in
--           DLT_DB.OPS.PIPELINE_RUNS (SPORT = 'NFL'), maintained by
--           SP_OBS_REFRESH (sql/ops/04_run_summary.sql), which discovers sports
--           from PIPELINE_REGISTRY at run time. Nothing per-sport remains to
--           create here, and that is the point: sport N+1 needs no file like
--           this at all.
-- Run as  : DLT_LOADER_ROLE, which owned the view.
-- Apply   : make setup-source SOURCE=nfl CONFIRM=1  (or snow sql -f directly)
--
-- The view's one structural idea, the time-window join against this database's
-- OPS._DLT_RUNS (no query id exists in _DLT_RUNS, so pipeline name + finished-
-- inside-the-task-window is the join), moved into SP_OBS_REFRESH's per-sport
-- MERGE, together with the DLT_RECORD_MISSING boundary guard. The improvement
-- path also still stands: stamping SNOWFLAKE_SERVICE_NAME onto the record in
-- pipelines/common/observability.py would turn the window join into an equality
-- join, and is worth doing before any pipeline is scheduled more than once an
-- hour.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

DROP VIEW IF EXISTS NFL_PROD_DB.OPS.V_PIPELINE_RUNS;
