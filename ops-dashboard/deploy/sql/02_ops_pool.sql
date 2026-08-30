-- =============================================================================
-- ops-dashboard/deploy/sql/02_ops_pool.sql
-- Purpose : A dedicated always-on pool for the dashboard service.
-- Run as  : SYSADMIN; applied by hand via `make setup CONFIRM=1`.
--
-- WHY NOT DLT_POOL OR DLT_DEV_POOL
--   Both existing pools auto-suspend (300s / 120s) because batch jobs are
--   bursty, and a long-lived service on a suspending pool either pins the
--   pool awake (defeating the suspend for the jobs) or gets its node
--   recycled. A service also competes for nodes with scheduled jobs at cron
--   time. XS is the smallest family and one node is plenty: the container
--   serves one team and its queries run on DLT_WH, not on this pool.
--
-- COST, STATED SO IT IS A DECISION
--   CPU_X64_XS at MIN 1 with no auto-suspend runs 24/7. That is the price of
--   a dashboard that is up when you look at it. If that is not worth it,
--   AUTO_SUSPEND_SECS plus AUTO_RESUME makes it lazy at the cost of a cold
--   start on first view; the CREATE below keeps it always-on.
-- =============================================================================

USE ROLE SYSADMIN;

CREATE COMPUTE POOL IF NOT EXISTS OPS_DASHBOARD_POOL
    MIN_NODES = 1
    MAX_NODES = 1
    INSTANCE_FAMILY = CPU_X64_XS
    AUTO_RESUME = TRUE
    COMMENT = 'ops-dashboard SPCS service. Always-on, one XS node.';

GRANT USAGE, MONITOR ON COMPUTE POOL OPS_DASHBOARD_POOL TO ROLE OPS_DASHBOARD_ROLE;
