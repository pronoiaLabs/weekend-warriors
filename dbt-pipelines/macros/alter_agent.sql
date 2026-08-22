{% macro alter_agent(agent_name, spec) %}
  {%- set db = target.database -%}
  {%- set schema = target.schema -%}
  {%- set fqn = db ~ '.' ~ schema ~ '.' ~ agent_name -%}

  {# Update an existing agent so that CALLERS see the new spec. The spec is
     passed in as text by the per-agent wrapper macro (see
     agents/example_agent.sql); dbt Projects on Snowflake has no runtime
     file read.

     Cortex Agents are versioned. An unnamed call (Snowsight, the REST API) is
     served by the DEFAULT version, which is the latest COMMITTED version; the
     LIVE version is a mutable draft that nobody is served from once a default
     exists. So a deploy is four steps, not one: write the draft, commit it,
     point the default at the commit, reopen a draft for next time.

     Two facts measured on 2026-08-22, each of which silently defeated the
     one-step version of this macro:
       - ALTER AGENT ... MODIFY LIVE VERSION SET SPECIFICATION stores {} when
         handed the YAML that CREATE AGENT accepts. Handed JSON, it stores the
         spec. Hence the fromyaml | tojson below.
       - SET DEFAULT_VERSION = LAST is rejected as a syntax error even though
         the versioning guide shows it; the quoted id ('VERSION$4') works, and
         COMMIT's status row names the id it minted. #}

  {%- set spec_content = spec
        | replace('<<DATABASE>>', db)
        | replace('<<SCHEMA>>', schema)
        | replace('<<WAREHOUSE>>', target.warehouse) -%}
  {%- set spec_json = tojson(fromyaml(spec_content)) -%}

  {# 1. A live version must exist, and COMMIT consumes it, so a previous deploy
        (or a manual commit) may have left none. #}
  {%- set versions = run_query("SHOW VERSIONS IN AGENT " ~ fqn) -%}
  {%- set live = namespace(exists=false) -%}
  {%- for row in versions.rows -%}
    {%- if row['name'] is none -%}
      {%- set live.exists = true -%}
    {%- endif -%}
  {%- endfor -%}
  {%- if not live.exists -%}
    {% do run_query("ALTER AGENT " ~ fqn ~ " ADD LIVE VERSION FROM LAST") %}
  {%- endif -%}

  {# 2. Write the draft. #}
  {% set sql %}
    ALTER AGENT {{ fqn }}
      MODIFY LIVE VERSION SET SPECIFICATION = $${{ spec_json }}$$
  {% endset %}
  {% do run_query(sql) %}

  {# 3. Commit it; the status row reads "Version VERSION$N successfully committed." #}
  {%- set committed = run_query(
        "ALTER AGENT " ~ fqn ~ " COMMIT COMMENT = 'dbt deploy "
        ~ run_started_at.strftime('%Y-%m-%d %H:%M UTC') ~ "'") -%}
  {%- set status = committed.columns[0].values()[0] -%}
  {%- set version_id = status.split(' ')[1] -%}
  {%- if not version_id.startswith('VERSION$') -%}
    {{ exceptions.raise_compiler_error(
        "alter_agent: could not read the committed version id from '" ~ status ~ "'") }}
  {%- endif -%}

  {# 4. Serve it. 5. Reopen a draft so the next deploy finds a live version. #}
  {% do run_query("ALTER AGENT " ~ fqn ~ " SET DEFAULT_VERSION = '" ~ version_id ~ "'") %}
  {% do run_query("ALTER AGENT " ~ fqn ~ " ADD LIVE VERSION FROM LAST") %}

  {{ log("Agent updated: " ~ fqn ~ " now serves " ~ version_id, info=True) }}
{% endmacro %}
