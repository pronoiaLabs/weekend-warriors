-- =============================================================================
-- 10_dim_facts_cutover.sql (nfl) -- one-time CORE -> DIM + FACTS migration
-- =============================================================================
-- The single CORE schema split into DIM (dimensions, id bridges, PLAYER_SEARCH)
-- and FACTS (wide vendor-enriched facts, fantasy UDFs), with physical names
-- renamed (schema carries the role: DIM.PLAYER_PROFILE, FACTS.PLAY_LOG).
-- Strategy: docs/nfl-core-connection-strategy.html at the repo root.
--
-- This file holds only the deltas that re-running the sibling files cannot
-- express. Apply with the usual glob -- order matters and the glob provides it:
--
--     make setup-source SOURCE=nfl CONFIRM=1
--
--   01 creates DIM and FACTS (CORE is no longer in its list),
--   05 transfers their ownership to DBT_RUNNER_ROLE,
--   09 creates DIM.PLAYER_SEARCH,
--   10 (this file) may only THEN retire the CORE service and stamp the freeze.
--
-- Fresh accounts: CORE never existed there, every statement is IF EXISTS, and
-- the whole file is a no-op. Do not delete it for their sake -- it documents
-- why no CORE schema exists.
--
-- CORE itself is NOT dropped. dbt drops nothing at a cutover: the tables
-- freeze at last-run state, and the frozen schema is the instant rollback
-- (revert the dbt config + two macro literals and dbt rebuilds into it,
-- because DBT_RUNNER_ROLE keeps its ownership). The stamp below carries the
-- drop instruction so the archive cannot quietly become a stale shadow copy.
--
-- Roles: DBT_RUNNER_ROLE throughout -- it owns CORE (05 transferred it before
-- the split), owns the old service, and owns the schema comment.
-- =============================================================================

USE ROLE DBT_RUNNER_ROLE;

-- The DIM service exists (09 ran earlier in this same glob); retire the old
-- one so exactly one PLAYER_SEARCH serves SP_PLAYER_BRIDGE.
DROP CORTEX SEARCH SERVICE IF EXISTS NFL_PROD_DB.CORE.PLAYER_SEARCH;

-- Freeze stamp. The old fantasy UDFs (NFL_FANDUEL_POINTS, NFL_DRAFTKINGS_POINTS)
-- freeze here with everything else; dbt's on-run-start hook recreates them in
-- FACTS on the first post-cutover run.
ALTER SCHEMA IF EXISTS NFL_PROD_DB.CORE SET COMMENT =
    'FROZEN 2026-08-24 at the DIM + FACTS cutover (docs/nfl-core-connection-strategy.html). No longer a dbt target; read-only rollback archive. DROP SCHEMA after two prod release cycles -- target 2026-09-30.';
