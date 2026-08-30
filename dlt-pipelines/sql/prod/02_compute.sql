-- =============================================================================
-- prod/02_compute.sql
-- Purpose : Create the PRODUCTION compute -- an SPCS compute pool (runs the dlt
--           container) and a Gen2 multi-cluster warehouse (runs MERGE/COPY) --
--           and grant them to DLT_LOADER_ROLE.
-- Run as  : SYSADMIN. Creating a compute pool needs the account-level CREATE
--           COMPUTE POOL privilege, granted to SYSADMIN by
--           base/00_accountadmin_grants.sql (part of make setup-base).
-- Prerequisites : base/00_accountadmin_grants.sql, base/01_roles.sql.
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

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. SPCS compute pool
-- ---------------------------------------------------------------------------
CREATE COMPUTE POOL IF NOT EXISTS DLT_POOL
    MIN_NODES          = 1
    MAX_NODES          = 10
    INSTANCE_FAMILY    = CPU_X64_S
    AUTO_SUSPEND_SECS  = 300
    AUTO_RESUME        = TRUE
    COMMENT            = 'Production SPCS compute pool for dlt job services. CPU_X64_S (2 vCPU / 8 GiB).';

-- WIDENING AN ACCOUNT THAT ALREADY HAS THE POOL.
-- CREATE COMPUTE POOL IF NOT EXISTS above is a NO-OP once the pool exists, so editing
-- MAX_NODES up there changes nothing on an account that has already run this file. This
-- ALTER is what does it, and it is safe to re-run. Same pattern as the ALTER TABLE in
-- sql/base/03_registry.sql, and for the same reason.
--
-- MAX_NODES IS A CEILING, NOT A RESERVATION. Billing is per node that is actually
-- running: raising the maximum costs nothing while the pool is idle, and the pool
-- suspends entirely after AUTO_SUSPEND_SECS. MIN_NODES is the property that holds warm
-- capacity, which is why it stays at 1.
--
-- 3 was sized for one sport. Each additional league adds roughly ten scheduled Tasks,
-- and staggering them one per hour runs out of hours long before the work runs out. A
-- job that cannot get a node waits rather than failing, so the symptom of leaving this
-- at 3 would be Tasks quietly finishing late, which is harder to notice than an error.
ALTER COMPUTE POOL DLT_POOL SET MAX_NODES = 10;

GRANT USAGE   ON COMPUTE POOL DLT_POOL TO ROLE DLT_LOADER_ROLE;
GRANT MONITOR ON COMPUTE POOL DLT_POOL TO ROLE DLT_LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- 2. Job warehouse (Gen2 multi-cluster)
--
-- THE single job warehouse since the 2026-08 consolidation: dlt loads, the
-- dbt build/test/harvest tasks, and the observability layer all run here.
-- Three separate XS warehouses spent ~2/3 of their metered compute on 60s
-- resume minimums and auto-suspend tails from staggered wakes; one warehouse
-- shares those. Cost attribution moved to task COST_CENTER tags + dbt
-- QUERY_TAGs (sql/ops/08_cost_tags.sql).
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

-- dbt runs here too (base/04 creates the role before this warehouse exists,
-- so the grant lives here, beside the warehouse).
GRANT USAGE, OPERATE ON WAREHOUSE DLT_WH TO ROLE DBT_RUNNER_ROLE;
