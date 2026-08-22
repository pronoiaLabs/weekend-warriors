-- =============================================================================
-- dev/02_compute.sql
-- Purpose : Create the DEVELOPMENT compute -- DLT_DEV_POOL + ML_DEV_POOL and a
--           single-cluster warehouse -- so dev runs are isolated from prod for
--           cost attribution and blast radius. DLT_DEV_* granted to DLT_DEV_ROLE;
--           ML_DEV_POOL stays SYSADMIN (Snowflake ML batch jobs, not dlt).
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

-- Isolated from DLT_DEV_POOL so an ML batch job cannot steal the dlt-dev node.
-- Tagged 'dev' in ops/08_cost_tags.sql (COST_CENTER has no 'ml' value).
CREATE COMPUTE POOL IF NOT EXISTS ML_DEV_POOL
    MIN_NODES          = 1
    MAX_NODES          = 1
    INSTANCE_FAMILY    = CPU_X64_S
    AUTO_SUSPEND_SECS  = 120
    AUTO_RESUME        = TRUE
    COMMENT            = 'Dev SPCS pool for Snowflake ML batch inference. CPU_X64_S (2 vCPU / 8 GiB). Not DLT_POOL.';

GRANT USAGE   ON COMPUTE POOL ML_DEV_POOL TO ROLE SYSADMIN;
GRANT MONITOR ON COMPUTE POOL ML_DEV_POOL TO ROLE SYSADMIN;

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
