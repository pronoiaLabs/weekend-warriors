{#
    Umbrella deploy macros: one run-operation per sport deploys that sport's
    WHOLE agent roster. The Makefile's deploy-agent target (and through it
    deploy.yml's agents job) calls deploy_<sport>_agents, so adding an agent
    to a sport means adding a line here, never touching CI.

    Why the existence check: the deploy path always asks for alter=true (the
    zero-downtime versioned update), but alter_agent opens with SHOW VERSIONS
    IN AGENT, which errors on an agent that does not exist yet. On the first
    deploy of a new agent the check downgrades that one agent to create_agent
    while the rest of the roster still alters in place.
#}

{% macro agent_exists(agent_name) %}
  {%- set rows = run_query(
        "show agents like '" ~ agent_name ~ "' in schema "
        ~ target.database ~ "." ~ target.schema) -%}
  {{ return(rows.rows | length > 0) }}
{% endmacro %}


{% macro deploy_nfl_agents(alter=false) %}
  {% do deploy_nfl_analyst(alter=alter and agent_exists('nfl_analyst')) %}
  {% do deploy_nfl_team_form_analyst(alter=alter and agent_exists('nfl_team_form_analyst')) %}
  {% do deploy_nfl_player_analyst(alter=alter and agent_exists('nfl_player_analyst')) %}
  {% do deploy_nfl_situation_analyst(alter=alter and agent_exists('nfl_situation_analyst')) %}
  {% do deploy_nfl_availability_analyst(alter=alter and agent_exists('nfl_availability_analyst')) %}
  {% do deploy_nfl_market_analyst(alter=alter and agent_exists('nfl_market_analyst')) %}
{% endmacro %}


{% macro deploy_wnba_agents(alter=false) %}
  {% do deploy_wnba_analyst(alter=alter and agent_exists('wnba_analyst')) %}
{% endmacro %}


{% macro deploy_ncaaf_agents(alter=false) %}
  {% do deploy_ncaaf_analyst(alter=alter and agent_exists('ncaaf_analyst')) %}
{% endmacro %}
