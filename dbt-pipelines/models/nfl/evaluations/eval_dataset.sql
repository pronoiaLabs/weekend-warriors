{{ config(materialized='table') }}

-- =============================================================================
-- Evaluation Dataset
-- =============================================================================
-- Transforms the eval_ground_truth seed CSV into the format required by
-- Cortex Agent evaluations: input_query (VARCHAR) + ground_truth (VARIANT).
--
-- The ground_truth column must be VARIANT. Use PARSE_JSON, not OBJECT_CONSTRUCT.
-- =============================================================================

SELECT
    input_query,
    PARSE_JSON(ground_truth_json) AS ground_truth
FROM {{ ref('eval_ground_truth') }}
