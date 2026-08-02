{#
  Agent spec + deploy wrapper for "example_agent".

  dbt Projects on Snowflake has NO runtime file read (load_file_contents and
  {% include %} both fail), so each agent's spec lives inside a wrapper macro
  that passes the spec text to create_agent / alter_agent.

  Deploy (create or replace):   dbt run-operation deploy_example_agent
  Zero-downtime live update:    dbt run-operation deploy_example_agent --args '{alter: true}'

  The <<DATABASE>>, <<SCHEMA>>, and <<WAREHOUSE>> tokens are substituted with
  the active environment's target values by create_agent / alter_agent.

  Keep the three instruction layers separate (see README -> "Writing effective
  agents"):
    - instructions.orchestration = WHAT to do: tool routing, intent defaults,
      scope limits, multi-step workflow, fallback behavior.
    - instructions.response      = HOW the answer sounds/looks: tone, structure,
      tables vs charts, units, freshness.
    - tools[].description        = what each tool covers and when (not) to use.
  Do NOT put SQL-generation rules (rounding, synonyms, default filters) here;
  those belong in the semantic view's AI_SQL_GENERATION clause.
#}
{% macro deploy_example_agent(alter=false) %}
{%- set spec -%}
models:
  orchestration: auto     # 'auto' lets Snowflake pick the best model

orchestration:
  budget:
    seconds: 30           # Max time per request (raise for long multi-step runs)
    tokens: 16000         # Max orchestration tokens per request

instructions:
  response: >
    TODO: Describe how the agent should respond. Example: You are a data analyst
    assistant. Lead with the direct answer, then supporting detail. Use a table
    for multi-row results and a chart for trends. Include units and state the
    time period covered.
  orchestration: >
    TODO: Describe how the agent should route between tools. Example: For
    quantitative questions about orders and inventory, use the Analyst tool. For
    business definitions or policies, use the Search tool. If no time period is
    given, default to the most recent complete month. If a tool returns no rows,
    say so and suggest a related question.
  sample_questions:
    - question: "TODO: Add a sample question for Cortex Analyst"
    - question: "TODO: Add a sample question for Cortex Search"

tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "Analyst"
      description: >
        TODO: Describe what structured data this tool queries. Example: What it
        does: answers revenue, demand, and fulfillment questions over structured
        order, inventory, and product data. Data: fact and dimension tables at
        order grain, ~24 months of history. When to use: quantitative
        sales/inventory questions. When NOT to use: business definitions or
        policy questions (use the Search tool).

tool_resources:
  Analyst:
    # <<DATABASE>>.<<SCHEMA>> resolves to the active environment's target;
    # in dev that is your per-developer schema, in prod the shared schema.
    semantic_view: "<<DATABASE>>.<<SCHEMA>>.SV_EXAMPLE"
    execution_environment:
      type: warehouse
      warehouse: <<WAREHOUSE>>
{%- endset -%}

  {% if alter %}
    {{ alter_agent('example_agent', spec) }}
  {% else %}
    {{ create_agent('example_agent', spec) }}
  {% endif %}
{% endmacro %}
