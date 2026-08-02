{% macro run_evaluation(agent_name, run_name, config_file) %}

  {%- set db = target.database -%}
  {%- set schema = target.schema -%}
  {%- set stage = db ~ '.' ~ schema ~ '.EVAL_CONFIG_STAGE' -%}

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
    CREATE STAGE IF NOT EXISTS {{ stage }}
      FILE_FORMAT = {{ db }}.{{ schema }}.eval_yaml_format
  {% endset %}

  {% do run_query(create_format) %}
  {% do run_query(create_stage) %}

  {% set start_eval %}
    CALL EXECUTE_AI_EVALUATION(
      'START',
      OBJECT_CONSTRUCT('run_name', '{{ run_name }}'),
      '@{{ stage }}/{{ config_file }}'
    )
  {% endset %}

  {% do run_query(start_eval) %}
  {{ log("Evaluation started: " ~ run_name ~ " for agent " ~ agent_name, info=True) }}

{% endmacro %}
