{{ config(materialized='semantic_view') }}

-- =============================================================================
-- Semantic View: sv_example
-- =============================================================================
-- TODO: Replace this skeleton with your actual semantic view definition.
-- The dbt_semantic_view package passes your SQL directly to Snowflake's
-- CREATE OR REPLACE SEMANTIC VIEW: full SQL API coverage, no package
-- upgrade needed for new Snowflake features.
--
-- Use the source() and ref() functions to reference tables so dbt handles
-- fully-qualified name resolution. (Written without the Jinja braces here
-- because dbt renders Jinja even inside SQL comments.)
--
-- CLAUSE ORDER MATTERS. Author them in this sequence:
--   TABLES -> RELATIONSHIPS -> FACTS -> DIMENSIONS -> METRICS -> COMMENT
--   -> AI_SQL_GENERATION -> AI_QUESTION_CATEGORIZATION -> AI_VERIFIED_QUERIES
-- COMMENT must come BEFORE the AI_* clauses; verified queries come last.
--
-- Best practices for Cortex Analyst accuracy (see README ->
-- "Writing effective semantic views"):
--   * Business names + a few hand-curated synonyms; skip auto-synonym spam.
--   * Comments should state business meaning, grain, and any exclusions.
--   * Model KPIs as METRICS (not raw columns); FACTS are row-level building
--     blocks; DIMENSIONS are what users group/filter by.
--   * Add SAMPLE_VALUES on categorical dimensions (+ IS_ENUM only when the
--     listed values are the COMPLETE set) to map phrasing to real values.
--   * Add AI_VERIFIED_QUERIES for common and failure-prone questions.
--   * Keep SQL rules (defaults, rounding, decoding) in AI_SQL_GENERATION here,
--     NOT in the agent.
--   * Keep scope tight: ~3-5 tables to start, roughly 50-100 columns total.
--   * Declare PRIMARY KEY / UNIQUE and explicit RELATIONSHIPS; if two tables
--     have multiple join paths, disambiguate a metric with USING (rel_name).
-- =============================================================================

TABLES (
  -- TODO: Define your logical tables with primary keys.
  -- Example (wrapped in raw so dbt does not render the Jinja in these comments):
  {% raw %}
  -- orders AS {{ source('raw', 'orders') }}
  --   PRIMARY KEY (order_id)
  --   COMMENT = 'Customer orders with fulfillment status',
  --
  -- products AS {{ ref('stg_products') }}
  --   PRIMARY KEY (product_id)
  --   COMMENT = 'Product catalog with inventory data'
  {% endraw %}

  placeholder AS {{ source('raw', 'placeholder_table') }}
    PRIMARY KEY (id)
    COMMENT = 'TODO: Replace with your first table'
)

-- RELATIONSHIPS (
--   -- TODO: Define foreign key relationships between tables.
--   -- Prefer a clean star shape; if two tables have multiple join paths,
--   -- disambiguate the affected METRIC with USING (relationship_name).
--   -- Example:
--   -- orders_to_products AS
--   --   orders (product_id) REFERENCES products
-- )

-- FACTS (
--   -- TODO: Define row-level expressions that metrics aggregate over.
--   -- A fact is evaluated per row (NOT aggregated); metrics then SUM/AVG/COUNT
--   -- the facts. The FACTS clause must appear BEFORE DIMENSIONS and METRICS.
--   -- Example:
--   -- orders.order_value AS order_total
--   --   COMMENT = 'Per-order revenue amount, before aggregation',
--   --
--   -- orders.is_fulfilled AS IFF(status = 'Fulfilled', 1, 0)
--   --   COMMENT = 'Row-level 1/0 flag used to compute fulfillment rate',
--   --
--   -- line_items.discounted_price AS l_extendedprice * (1 - l_discount)
--   --   COMMENT = 'Extended price after discount'
-- )

-- DIMENSIONS (
--   -- TODO: Define dimensions users will filter and group by.
--   -- Example:
--   -- products.product_name AS product_name
--   --   COMMENT = 'Product display name'
--   --   WITH SYNONYMS = ('item name', 'sku name'),
--   --
--   -- orders.status AS status
--   --   COMMENT = 'Order status'
--   --   SAMPLE_VALUES ('Placed', 'Fulfilled', 'Cancelled')  -- maps phrasing to real values
--   --   IS_ENUM,                                            -- only if this is the COMPLETE set
--   --
--   -- orders.order_date AS order_date
--   --   COMMENT = 'Date the order was placed'
-- )

-- METRICS (
--   -- TODO: Define aggregate metrics users will ask about.
--   -- Example:
--   -- orders.total_revenue AS SUM(order_total)
--   --   COMMENT = 'Total revenue from orders',
--   --
--   -- orders.order_count AS COUNT(order_id)
--   --   COMMENT = 'Number of orders placed'
-- )

-- AI_SQL_GENERATION
--   'TODO: Add business-specific SQL generation rules here.
--    Example: Default to the most recent date if no date is specified.
--    Always round currency values to 2 decimal places.'

-- AI_QUESTION_CATEGORIZATION
--   'TODO: Add guardrails for out-of-scope questions here.
--    Example: Reject questions about employee data or HR topics.'

-- AI_VERIFIED_QUERIES (
--   -- TODO: Add verified query pairs for common questions.
--   -- Example:
--   -- top_products AS (
--   --   QUESTION 'What are the top selling products?'
--   --   VERIFIED_AT 1747267200
--   --   ONBOARDING_QUESTION TRUE
--   --   SQL 'SELECT product_name, total_revenue
--   --        FROM SEMANTIC_VIEW(sv_example
--   --          DIMENSIONS products.product_name
--   --          METRICS orders.total_revenue)
--   --        ORDER BY total_revenue DESC
--   --        LIMIT 10'
--   -- )
-- )
