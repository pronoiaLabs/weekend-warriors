{% macro alter_agent(agent_name, spec) %}

  {%- set db = target.database -%}
  {%- set schema = target.schema -%}

  {# Zero-downtime update of an existing agent's live version. The spec is
     passed in as text by the per-agent wrapper macro (see
     agents/example_agent.sql); dbt Projects on Snowflake has no runtime
     file read. #}
  {%- set spec_content = spec
        | replace('<<DATABASE>>', db)
        | replace('<<SCHEMA>>', schema)
        | replace('<<WAREHOUSE>>', target.warehouse) -%}

  {% set sql %}
    ALTER AGENT {{ db }}.{{ schema }}.{{ agent_name }}
      MODIFY LIVE VERSION SET SPECIFICATION =
      $$
      {{ spec_content }}
      $$
  {% endset %}

  {% do run_query(sql) %}
  {{ log("Agent updated (live version): " ~ db ~ "." ~ schema ~ "." ~ agent_name, info=True) }}

{% endmacro %}
