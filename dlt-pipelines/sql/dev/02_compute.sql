-- =============================================================================
-- dev/02_compute.sql
-- Purpose : Create the DEVELOPMENT compute -- a small SPCS compute pool and a
--           single-cluster warehouse -- so dev runs are isolated from prod for
--           cost attribution and blast radius. Granted to DLT_DEV_ROLE.
-- Run as  : SYSADMIN. Creating a compute pool needs the account-level CREATE
--           COMPUTE POOL privilege; grant it to SYSADMIN once (see the commented
--           ACCOUNTADMIN line below) if your SYSADMIN does not already have it.
-- Prerequisites : base/01_roles.sql.
-- Cost note: kept intentionally small (single node / single cluster). Dev jobs
--            are ad-hoc, so AUTO_SUSPEND is short.
-- =============================================================================

-- One-time, only if SYSADMIN lacks the privilege (uncomment and run as ACCOUNTADMIN):
--   USE ROLE ACCOUNTADMIN;
--   GRANT CREATE COMPUTE POOL ON ACCOUNT TO ROLE SYSADMIN;

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. Dev SPCS compute pool
-- ---------------------------------------------------------------------------
CREATE COMPUTE POOL IF NOT EXISTS DLT_DEV_POOL
    MIN_NODES          = 1
    MAX_NODES          = 1
    INSTANCE_FAMILY    = CPU_X64_S
    AUTO_SUSPEND_SECS  = 120
    AUTO_RESUME        = TRUE
    COMMENT            = 'Development SPCS compute pool for ad-hoc dlt dev jobs. CPU_X64_S (2 vCPU / 8 GiB).';

GRANT USAGE   ON COMPUTE POOL DLT_DEV_POOL TO ROLE DLT_DEV_ROLE;
GRANT MONITOR ON COMPUTE POOL DLT_DEV_POOL TO ROLE DLT_DEV_ROLE;

-- ---------------------------------------------------------------------------
-- 2. Dev warehouse (single cluster -- concurrency isolation not needed for dev)
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS DLT_DEV_WH
    WAREHOUSE_SIZE        = XSMALL
    WAREHOUSE_TYPE        = STANDARD
    MAX_CONCURRENCY_LEVEL = 8
    MIN_CLUSTER_COUNT     = 1
    MAX_CLUSTER_COUNT     = 1
    AUTO_SUSPEND          = 60
    AUTO_RESUME           = TRUE
    INITIALLY_SUSPENDED   = TRUE
    COMMENT               = 'Single-cluster warehouse for dlt dev SQL execution.';

GRANT USAGE   ON WAREHOUSE DLT_DEV_WH TO ROLE DLT_DEV_ROLE;
GRANT OPERATE ON WAREHOUSE DLT_DEV_WH TO ROLE DLT_DEV_ROLE;
