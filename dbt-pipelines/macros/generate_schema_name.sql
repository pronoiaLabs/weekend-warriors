{#
    generate_schema_name -- layered schemas in prod, one schema in dev.

    dbt's default behaviour concatenates: a model with +schema: CORE running
    against target.schema=DEV_JSMITH lands in DEV_JSMITH_CORE. That would
    give every developer three schemas per environment.

    This override switches on DBT_COLLAPSE_SCHEMAS, injected by env.yml:

      dev  (collapse=true)   every layer  -> NFL_DEV_DB.DEV_<user>
      prod (collapse=false)  +schema wins -> NFL_PROD_DB.PREP / .CORE / .ANALYTICS

    Models with no +schema config fall back to target.schema in both cases.

    Note the env_var default of 'false': a run that somehow reaches dbt without
    env.yml resolution gets the layered (prod-shaped) behaviour rather than
    silently flattening everything into one schema.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}
    {%- set collapse = env_var('DBT_COLLAPSE_SCHEMAS', 'false') | lower == 'true' -%}

    {%- if custom_schema_name is none or collapse -%}
        {{ default_schema | trim }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}
