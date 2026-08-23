{#
    nfl_team_abbr_nflverse -- map a BallDontLie or Sleeper team abbreviation
    onto nflverse's.

    The three vendors agree on 29 of 32 clubs (measured 2026-08-23). nflverse
    writes LA and WAS where BallDontLie writes LAR and WSH; Sleeper writes WAS
    and still carries OAK on a few rows. Legacy codes fold onto the current
    club. Anything else passes through unchanged.

    MIRRORS TO_NFLVERSE_TEAM in
    dbt-pipelines/snowpark/player_bridge/src/player_bridge/evidence.py.
    Change one, change both; the unit tests there pin the Python side.

    Usage:
        {{ nfl_team_abbr_nflverse('team_abbreviation') }}
#}

{% macro nfl_team_abbr_nflverse(column_name) %}

    case upper(trim({{ column_name }}))
        when 'LAR' then 'LA'
        when 'WSH' then 'WAS'
        when 'OAK' then 'LV'
        when 'SD'  then 'LAC'
        when 'STL' then 'LA'
        else upper(trim({{ column_name }}))
    end

{% endmacro %}


{#
    nfl_position_group -- collapse any vendor's position code to its group.

    BallDontLie says LCB and WLB, nflverse says SAF and MLB, Sleeper says DB
    and OL: the vocabularies only agree at the group level, so that is the
    level the bridge compares on. Unknown codes (BDL's UNK) return NULL.

    MIRRORS POSITION_GROUPS in the Snowpark package (evidence.py) and the
    POS_GROUP case in dlt-pipelines/sql/sources/nfl/09_player_bridge.sql, the
    search service's filter attribute. Change one, change all three.

    Usage:
        {{ nfl_position_group('position') }}
#}

{% macro nfl_position_group(column_name) %}

    case upper(trim({{ column_name }}))
        when 'QB' then 'QB'
        when 'RB' then 'RB' when 'FB' then 'RB' when 'HB' then 'RB'
        when 'WR' then 'WR'
        when 'TE' then 'TE'
        when 'OL' then 'OL' when 'OT' then 'OL' when 'T' then 'OL' when 'G' then 'OL'
        when 'OG' then 'OL' when 'C' then 'OL'
        when 'DL' then 'DL' when 'DE' then 'DL' when 'DT' then 'DL' when 'NT' then 'DL'
        when 'EDGE' then 'DL'
        when 'LB' then 'LB' when 'ILB' then 'LB' when 'OLB' then 'LB' when 'MLB' then 'LB'
        when 'WLB' then 'LB' when 'SLB' then 'LB'
        when 'DB' then 'DB' when 'CB' then 'DB' when 'S' then 'DB' when 'SS' then 'DB'
        when 'FS' then 'DB' when 'SAF' then 'DB' when 'LCB' then 'DB' when 'RCB' then 'DB'
        when 'K' then 'SPEC' when 'PK' then 'SPEC' when 'P' then 'SPEC' when 'LS' then 'SPEC'
        when 'KR' then 'SPEC' when 'PR' then 'SPEC'
    end

{% endmacro %}


{#
    nfl_player_bridge_fqn -- where SP_PLAYER_BRIDGE writes for this target.

    The procedure takes the target database and schema as arguments and the
    bridge model's pre_hook passes its own (this.database, this.schema). Tests
    and other readers need the same address without a model to hang it on:
    generate_schema_name('CORE') resolves to CORE in prod and to the
    developer's single schema in dev, exactly as the model's +schema does.
    Same pattern as nfl_fantasy_points_fqn.

    Usage:
        {{ nfl_player_bridge_fqn() }}                    -> ...PLAYER_BRIDGE
        {{ nfl_player_bridge_fqn('PLAYER_BRIDGE_UNMATCHED') }}
#}

{% macro nfl_player_bridge_fqn(table_name='PLAYER_BRIDGE') -%}
    {{ target.database }}.{{ generate_schema_name('CORE', none) | trim }}.{{ table_name }}
{%- endmacro %}
