-- =============================================================================
-- sources/wnba/04_run_summary.sql
-- Purpose : Retire the per-sport run-summary view. WNBA run rows now live in
--           DLT_DB.OPS.PIPELINE_RUNS (SPORT = 'WNBA'), maintained by
--           SP_OBS_REFRESH (sql/ops/04_run_summary.sql), which discovers sports
--           from PIPELINE_REGISTRY at run time. See sources/nfl/04 for the full
--           story; sport N+1 needs no file like this at all.
-- Run as  : DLT_LOADER_ROLE, which owned the view.
-- Apply   : make setup-source SOURCE=wnba CONFIRM=1  (or snow sql -f directly)
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

DROP VIEW IF EXISTS WNBA_PROD_DB.OPS.V_PIPELINE_RUNS;
