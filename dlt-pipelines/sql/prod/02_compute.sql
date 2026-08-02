-- =============================================================================
-- prod/02_compute.sql
-- Purpose : Create the PRODUCTION compute -- an SPCS compute pool (runs the dlt
--           container) and a Gen2 multi-cluster warehouse (runs MERGE/COPY) --
--           and grant them to DLT_LOADER_ROLE.
-- Run as  : SYSADMIN. Creating a compute pool needs the account-level CREATE
--           COMPUTE POOL privilege; grant it to SYSADMIN once (see the commented
--           ACCOUNTADMIN line below) if your SYSADMIN does not already have it.
-- Prerequisites : base/01_roles.sql.
-- Cost note: CPU_X64_S = 0.11 credits/hr per node. SPCS bills in 1-minute
--            increments with a 5-minute minimum per job run. MAX_NODES caps
--            concurrent jobs; adjust to your concurrency needs.
--
-- Edition/region notes:
--   Multi-cluster (MIN != MAX) requires Enterprise Edition or higher.
--   On Standard Edition set MIN_CLUSTER_COUNT = MAX_CLUSTER_COUNT = 1.
--   Gen2 (GENERATION = '2') is unavailable in a few regions (AWS af-south-1,
--   eu-central-2; GCP me-central1; Azure us-gov-virginia) -- use Gen1 there.
-- =============================================================================

-- One-time, only if SYSADMIN lacks the privilege (uncomment and run as ACCOUNTADMIN):
--   USE ROLE ACCOUNTADMIN;
--   GRANT CREATE COMPUTE POOL ON ACCOUNT TO ROLE SYSADMIN;

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. SPCS compute pool
-- ---------------------------------------------------------------------------
CREATE COMPUTE POOL IF NOT EXISTS DLT_POOL
    MIN_NODES          = 1
    MAX_NODES          = 3
    INSTANCE_FAMILY    = CPU_X64_S
    AUTO_SUSPEND_SECS  = 300
    AUTO_RESUME        = TRUE
    COMMENT            = 'Production SPCS compute pool for dlt job services. CPU_X64_S (2 vCPU / 8 GiB).';

GRANT USAGE   ON COMPUTE POOL DLT_POOL TO ROLE DLT_LOADER_ROLE;
GRANT MONITOR ON COMPUTE POOL DLT_POOL TO ROLE DLT_LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- 2. Load warehouse (Gen2 multi-cluster)
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS DLT_WH
    WAREHOUSE_SIZE        = XSMALL
    WAREHOUSE_TYPE        = STANDARD
    MAX_CONCURRENCY_LEVEL = 8
    MIN_CLUSTER_COUNT     = 1
    MAX_CLUSTER_COUNT     = 3               -- set =1 on Standard Edition
    SCALING_POLICY        = 'STANDARD'
    AUTO_SUSPEND          = 60
    AUTO_RESUME           = TRUE
    INITIALLY_SUSPENDED   = TRUE
    ENABLE_QUERY_ACCELERATION = FALSE
    COMMENT               = 'Gen2 multi-cluster warehouse for dlt SQL execution (MERGE, COPY, schema inference).';
-- Confirm Gen2 is active: SHOW WAREHOUSES LIKE 'DLT_WH'; -> "type" column shows "Snowflake Gen 2".

GRANT USAGE   ON WAREHOUSE DLT_WH TO ROLE DLT_LOADER_ROLE;
GRANT OPERATE ON WAREHOUSE DLT_WH TO ROLE DLT_LOADER_ROLE;
