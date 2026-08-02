{% macro create_agent(agent_name, spec) %}

  {%- set db = target.database -%}
  {%- set schema = target.schema -%}

  {# Substitute the environment tokens in the spec with the resolved target
     values. The spec is passed in as text by the per-agent wrapper macro
     (see agents/example_agent.sql) because dbt Projects on Snowflake has no
     runtime file read. #}
  {%- set spec_content = spec
        | replace('<<DATABASE>>', db)
        | replace('<<SCHEMA>>', schema)
        | replace('<<WAREHOUSE>>', target.warehouse) -%}

  {% set sql %}
    CREATE OR REPLACE AGENT {{ db }}.{{ schema }}.{{ agent_name }}
      COMMENT = 'Managed by dbt - do not edit manually'
      FROM SPECIFICATION
      $$
      {{ spec_content }}
      $$
  {% endset %}

  {% do run_query(sql) %}
  {{ log("Agent created: " ~ db ~ "." ~ schema ~ "." ~ agent_name, info=True) }}

{% endmacro %}
