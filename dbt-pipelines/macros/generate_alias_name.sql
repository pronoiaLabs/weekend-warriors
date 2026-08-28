{#
    Physical table names for the NFL DIM/FACTS layer.

    The schema carries the role (DIM.PLAYER_PROFILE, FACTS.PLAY_LOG), so the
    dim_/fact_ prefix comes off the physical name. dbt model names do NOT
    change: every ref(), semantic view and APP mart compiles untouched --
    only the rendered relation name differs. Scoped to models under
    models/nfl/core/ so NCAAF and the nfl prep/features/app/semantic
    trees keep dbt's default (alias = model name).

    Overrides name the tables whose stripped name would be a single word or
    misleading (naming convention: two words minimum, per
    docs/nfl-enrichment-columns.html). Everything else is a plain prefix
    strip. Bridges fall through unchanged -- BRIDGE_PLAYER_IDS stays itself.

    Dev note: aliases apply under DBT_COLLAPSE_SCHEMAS too, so a dev schema
    rehearses the renames (PLAYER_PROFILE lands in DEV_<user>); the old
    DIM_*/FACT_* tables there become orphans dbt no longer manages and are
    dropped by hand.
#}

{% macro generate_alias_name(custom_alias_name=none, node=none) -%}
    {%- if custom_alias_name -%}
        {{ custom_alias_name | trim }}
    {%- elif node is not none
          and node.resource_type == 'model'
          and node.path.replace('\\', '/').startswith('nfl/core/') -%}
        {%- set overrides = {
            'dim_player':  'PLAYER_PROFILE',
            'dim_team':    'TEAM_PROFILE',
            'dim_game':    'GAME_SCHEDULE',
            'dim_date':    'CALENDAR_DATE',
            'dim_stadium': 'STADIUM_PROFILE',
            'fact_play':   'PLAY_LOG',
            'fact_trade':  'TRADE_ASSET',
            'fact_game_betting_odds_opening':  'GAME_ODDS_OPENING',
            'fact_game_betting_odds_snapshot': 'GAME_ODDS_SNAPSHOT',
            'fact_game_betting_odds_closing':  'GAME_ODDS_CLOSING',
        } -%}
        {%- if node.name in overrides -%}
            {{ overrides[node.name] }}
        {%- elif node.name.startswith('dim_') -%}
            {{ node.name[4:] | upper }}
        {%- elif node.name.startswith('fact_') -%}
            {{ node.name[5:] | upper }}
        {%- else -%}
            {{ node.name | upper }}
        {%- endif -%}
    {%- else -%}
        {{ node.name }}
    {%- endif -%}
{%- endmacro %}
