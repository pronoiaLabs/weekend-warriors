-- =============================================================================
-- dev/03_development_wh.sql
-- Purpose : DEVELOPMENT_WH, the interactive/dev warehouse everything outside
--           the dlt loaders assumes exists:
--             * dbt-pipelines/env.yml -- every *_dev environment sets
--               DBT_WAREHOUSE: DEVELOPMENT_WH
--             * the recommended snow connection (connections.toml.example)
--             * analytics-dashboard `make fixtures` capture
--           It predates this file on the original account (created by hand),
--           which is why nothing else in sql/ mentions creating it.
-- Run as  : SYSADMIN.
-- Apply   : make setup-dev CONFIRM=1
--
-- Values mirror the original: XS, auto-suspend 300s, single cluster.
-- Tagged 'dev' by ops/08_cost_tags.sql, which already lists this warehouse.
-- =============================================================================

USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS DEVELOPMENT_WH
    WAREHOUSE_SIZE        = XSMALL
    WAREHOUSE_TYPE        = STANDARD
    MIN_CLUSTER_COUNT     = 1
    MAX_CLUSTER_COUNT     = 1
    AUTO_SUSPEND          = 300
    AUTO_RESUME           = TRUE
    INITIALLY_SUSPENDED   = TRUE
    COMMENT               = 'Interactive development warehouse: dbt dev builds, ad-hoc queries.';

GRANT USAGE   ON WAREHOUSE DEVELOPMENT_WH TO ROLE DLT_DEV_ROLE;
GRANT OPERATE ON WAREHOUSE DEVELOPMENT_WH TO ROLE DLT_DEV_ROLE;
