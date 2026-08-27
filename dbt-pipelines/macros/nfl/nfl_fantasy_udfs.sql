{#
    nfl_fantasy_udfs -- fantasy scoring as Snowflake SQL UDFs, one per book.

    The math lives in ONE place, as functions, so the fact that stores the
    points and any ad hoc query (a season total, a what-if on a projected stat
    line) agree by construction. SQL UDFs are inlined by Snowflake, so there is
    no per-row call overhead.

    Every book scores the same thirteen inputs; they differ only in the
    coefficients below. Add a book by adding a row; everything else is shared.

      book         reception   fumble_lost   (everything else identical)
      fanduel      0.5         -2            .docs/fanduel/scroring.md
      draftkings   1.0         -1            .docs/draftkings/scoring.md

    Shared rules, offensive players only:
      0.1 per receiving yard, +3 at 100; 6 per receiving TD
      0.1 per rushing yard, +3 at 100; 6 per rushing TD
      0.04 per passing yard, +3 at 300; 4 per passing TD; -1 per INT thrown
      6 per own-fumble-recovery TD; 6 per kick/punt (DraftKings: or FG) return TD
      2 per two-point conversion rushed or caught; 2 per two-point pass thrown
    Kickers (field goals by distance) and team defenses are not scored here.

    WHERE THEY LIVE. create_nfl_fantasy_udfs() runs from dbt_project.yml's
    on-run-start, so every run that can build fact_player_game_offense first
    guarantees the functions exist, in the same schema the fact models resolve
    to: NFL_PROD_DB.FACTS in prod, NFL_DEV_DB.DEV_<user> in dev (via
    generate_schema_name). Gated on DBT_SPORT = nfl so a WNBA or NCAAF run never
    plants an NFL function in its own database. Every argument is coalesced to
    0 inside the function, so callers pass raw nullable measures.

    Usage in a model:
        {{ nfl_fantasy_points_fqn('fanduel') }}(receptions, receiving_yards, ...)
#}

{% macro nfl_fantasy_books() %}
    {{ return({
        'fanduel':    {'reception': 0.5, 'fumble_lost': -2},
        'draftkings': {'reception': 1.0, 'fumble_lost': -1},
    }) }}
{% endmacro %}


{% macro nfl_fantasy_points_fqn(book) -%}
    {{ target.database }}.{{ generate_schema_name('FACTS', none) | trim }}.NFL_{{ book | upper }}_POINTS
{%- endmacro %}


{% macro create_nfl_fantasy_udfs() %}

    {%- if execute and env_var('DBT_SPORT', 'nfl') == 'nfl' -%}

    {%- for book, c in nfl_fantasy_books().items() %}

    {% set sql %}
        create or replace function {{ nfl_fantasy_points_fqn(book) }}(
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
        comment = '{{ book | capitalize }} NFL fantasy points for one offensive player-game. Managed by dbt (macros/nfl/nfl_fantasy_udfs.sql); do not edit by hand.'
        as
        $$
            round(
                  {{ c['reception'] }} * coalesce(receptions, 0)
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
                + ({{ c['fumble_lost'] }}) * coalesce(fumbles_lost, 0)
                + 6    * coalesce(fumble_recovery_tds, 0)
                + 6    * coalesce(return_touchdowns, 0)
                + 2    * coalesce(two_point_conversions, 0)
                + 2    * coalesce(two_point_thrown, 0)
            , 2)
        $$
    {% endset %}

    {% do run_query(sql) %}
    {{ log("Created UDF " ~ nfl_fantasy_points_fqn(book), info=True) }}

    {%- endfor %}

    {%- endif -%}

{% endmacro %}
