{# =============================================================================
   Snowflake QUERY_TAG override
   =============================================================================
   dbt-snowflake wraps every materialization in set_query_tag() /
   unset_query_tag(), dispatched to snowflake__set_query_tag. Defining the
   snowflake__ variants here (root project) wins the dispatch search, so every
   model/test/snapshot query carries a JSON tag:

     {"app":"dbt","sport":"nfl","env":"prod","build_id":"<uuid>","node":"model.x.y"}

   The pieces:
     * DBT_QUERY_TAG_BASE  -- JSON base injected per environment by env.yml and
       also set session-wide via profiles.yml query_tag, so statements outside
       a materialization (connection setup, metadata) still carry the base.
     * DBT_BUILD_ID        -- passed by SP_DBT_BUILD through EXECUTE DBT PROJECT
       ENV_VARS. 'manual' when absent (dev runs, ad-hoc executes), so the
       harvest can tell triggered builds from hand runs.
     * node                -- the dbt unique_id, the per-query attribution the
       ops dashboard joins on.

   The tag is the correlation key for the whole observability chain
   (DLT_DB.OPS.DBT_QUERY_LOG and the operator-stats harvest); change the JSON
   shape only together with dlt-pipelines/sql/ops/ and the dashboard API.

   Upstream shape being overridden:
   https://github.com/dbt-labs/dbt-snowflake/blob/main/dbt/include/snowflake/macros/adapters.sql
   ============================================================================= #}

{% macro snowflake__set_query_tag() -%}
  {% set original_query_tag = get_current_query_tag() %}
  {% set tag = fromjson(env_var('DBT_QUERY_TAG_BASE', '{"app":"dbt"}')) %}
  {% do tag.update({'build_id': env_var('DBT_BUILD_ID', 'manual')}) %}
  {% if model is defined and model %}
    {% do tag.update({'node': model.unique_id}) %}
  {% endif %}
  {# A model-level +query_tag config, if anyone ever sets one, still wins. #}
  {% set config_tag = config.get('query_tag') %}
  {% if config_tag %}
    {% do tag.update({'config_tag': config_tag}) %}
  {% endif %}
  {% set new_query_tag = tojson(tag) %}
  {% if new_query_tag != original_query_tag %}
    {% do run_query("alter session set query_tag = '" ~ new_query_tag ~ "'") %}
    {{ return(original_query_tag) }}
  {% endif %}
  {{ return(none) }}
{%- endmacro %}

{% macro snowflake__unset_query_tag(original_query_tag) -%}
  {# No-op: keep the signature so dispatch still matches. The next node's
     set_query_tag still ALTERs because `node` changed. Harvest still sees
     `node` on the tagged SQL. Cuts one ALTER SESSION per node. #}
  {{ return(none) }}
{%- endmacro %}
