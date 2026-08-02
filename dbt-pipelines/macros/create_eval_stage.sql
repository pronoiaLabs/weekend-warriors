{% macro create_eval_stage() %}

  {%- set db = target.database -%}
  {%- set schema = target.schema -%}

  {% set create_format %}
    CREATE OR REPLACE FILE FORMAT {{ db }}.{{ schema }}.eval_yaml_format
      TYPE = 'CSV'
      FIELD_DELIMITER = NONE
      RECORD_DELIMITER = '\n'
      SKIP_HEADER = 0
      FIELD_OPTIONALLY_ENCLOSED_BY = NONE
      ESCAPE_UNENCLOSED_FIELD = NONE
  {% endset %}

  {% set create_stage %}
    CREATE STAGE IF NOT EXISTS {{ db }}.{{ schema }}.EVAL_CONFIG_STAGE
      FILE_FORMAT = {{ db }}.{{ schema }}.eval_yaml_format
  {% endset %}

  {% do run_query(create_format) %}
  {% do run_query(create_stage) %}
  {{ log("Eval stage ready: " ~ db ~ "." ~ schema ~ ".EVAL_CONFIG_STAGE", info=True) }}

{% endmacro %}
