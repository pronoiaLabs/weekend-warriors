{#
    nfl_fanduel_points -- FanDuel NFL scoring as a Snowflake SQL UDF.

    The math lives in ONE place, as a function, so the fact that stores it and
    any ad hoc query (a season total, a what-if on a projected stat line) agree
    by construction. It is a SQL UDF, which Snowflake inlines into the calling
    query, so there is no per-row call overhead.

    FanDuel NFL scoring (.docs/fanduel/scroring.md), offensive players only:
      0.5 per reception; 0.1 per receiving yard, +3 at 100; 6 per receiving TD
      0.1 per rushing yard, +3 at 100; 6 per rushing TD
      0.04 per passing yard, +3 at 300; 4 per passing TD; -1 per INT thrown
      -2 per fumble lost; 6 per own-fumble-recovery TD; 6 per kick/punt return TD
      2 per two-point conversion rushed or caught; 2 per two-point pass thrown
    Kickers (field goals by distance) and team defenses are not scored here.

    WHERE IT LIVES. create_nfl_fanduel_udf() runs from dbt_project.yml's
    on-run-start, so every run that can build fact_player_game_offense first
    guarantees the function exists, in the same schema CORE models resolve to:
    NFL_PROD_DB.CORE in prod, NFL_DEV_DB.DEV_<user> in dev (via
    generate_schema_name). It is gated on DBT_SPORT = nfl so a WNBA or NCAAF
    run never plants an NFL function in its own database. Every argument is
    coalesced to 0 inside the function, so callers pass raw nullable measures.

    Usage in a model:
        {{ nfl_fanduel_points_fqn() }}(receptions, receiving_yards, ...)
#}

{% macro nfl_fanduel_points_fqn() -%}
    {{ target.database }}.{{ generate_schema_name('CORE', none) | trim }}.NFL_FANDUEL_POINTS
{%- endmacro %}


{% macro create_nfl_fanduel_udf() %}

    {%- if execute and env_var('DBT_SPORT', 'nfl') == 'nfl' -%}

    {% set sql %}
        create or replace function {{ nfl_fanduel_points_fqn() }}(
            receptions              number,
            receiving_yards         number,
            receiving_touchdowns    number,
            rushing_yards           number,
            rushing_touchdowns      number,
            passing_yards           number,
            passing_touchdowns      number,
            passing_interceptions   number,
            fumbles_lost            number,
            fumble_recovery_tds     number,
            return_touchdowns       number,
            two_point_conversions   number,
            two_point_thrown        number
        )
        returns number(8, 2)
        comment = 'FanDuel NFL fantasy points for one offensive player-game. Managed by dbt (macros/nfl/nfl_fanduel_udf.sql); do not edit by hand.'
        as
        $$
            round(
                  0.5  * coalesce(receptions, 0)
                + 0.1  * coalesce(receiving_yards, 0)
                + iff(coalesce(receiving_yards, 0) >= 100, 3, 0)
                + 6    * coalesce(receiving_touchdowns, 0)
                + 0.1  * coalesce(rushing_yards, 0)
                + iff(coalesce(rushing_yards, 0) >= 100, 3, 0)
                + 6    * coalesce(rushing_touchdowns, 0)
                + 0.04 * coalesce(passing_yards, 0)
                + iff(coalesce(passing_yards, 0) >= 300, 3, 0)
                + 4    * coalesce(passing_touchdowns, 0)
                - 1    * coalesce(passing_interceptions, 0)
                - 2    * coalesce(fumbles_lost, 0)
                + 6    * coalesce(fumble_recovery_tds, 0)
                + 6    * coalesce(return_touchdowns, 0)
                + 2    * coalesce(two_point_conversions, 0)
                + 2    * coalesce(two_point_thrown, 0)
            , 2)
        $$
    {% endset %}

    {% do run_query(sql) %}
    {{ log("Created UDF " ~ nfl_fanduel_points_fqn(), info=True) }}

    {%- endif -%}

{% endmacro %}
