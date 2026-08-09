{#
    wnba_parse_record -- pull a component out of a WNBA record string.

    The standings source stores split records as text: "11-6". Basketball has
    no ties, so unlike nfl_parse_record there is no third position and asking
    for one is a bug in the caller, not a data condition.

    Usage:
        {{ wnba_parse_record('home_record', 'wins') }}
#}

{% macro wnba_parse_record(column_name, part) %}

    {%- if part == 'wins' -%}
        try_cast(split_part({{ column_name }}, '-', 1) as int)
    {%- elif part == 'losses' -%}
        try_cast(split_part({{ column_name }}, '-', 2) as int)
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "wnba_parse_record: part must be one of wins/losses, got '" ~ part ~ "'. "
            ~ "Basketball has no ties; if you are porting NFL code, drop the ties term."
        ) }}
    {%- endif -%}

{% endmacro %}


{#
    wnba_win_pct -- WNBA winning percentage: W / (W + L).

    No tie term (see wnba_parse_record). Returns NULL rather than erroring when
    no games have been played, since a 0-0 team has no defined percentage.
#}

{% macro wnba_win_pct(wins_column, losses_column) %}

    case
        when coalesce({{ wins_column }}, 0) + coalesce({{ losses_column }}, 0) > 0
        then coalesce({{ wins_column }}, 0)
             / (coalesce({{ wins_column }}, 0) + coalesce({{ losses_column }}, 0))
    end

{% endmacro %}


{#
    wnba_season_type_name -- normalize the source's three season-type encodings
    into one vocabulary.

    The raw tables disagree on how to say "regular season":
      * PLAYER_SEASON_STATS / TEAM_SEASON_STATS: '2' / '3' (integer-as-text)
      * the advanced-season and shot-location tables: 'regular' / 'playoffs'
      * GAMES: a POSTSEASON boolean (handled in stg_wnba__games, not here,
        because games also need the All-Star and Preseason cases that only
        game context can decide)

    Canonical vocabulary: 'Preseason', 'Regular Season', 'Postseason',
    'All-Star'. Unrecognized inputs pass through as NULL so a new upstream
    encoding shows up as a not_null test failure instead of a silent bucket.
#}

{% macro wnba_season_type_name(column_name) %}

    case lower(trim({{ column_name }}))
        when '2' then 'Regular Season'
        when '3' then 'Postseason'
        when 'regular' then 'Regular Season'
        when 'playoffs' then 'Postseason'
    end

{% endmacro %}


{#
    wnba_coalesce_variant -- fold a dlt variant-split twin column back into one.

    Where the API mixed ints and floats across rows, dlt split the column in
    two: the base column kept the majority type and a sibling named
    <column>__V_DOUBLE holds the float rows. Reading only the base column
    silently drops those rows' values. The canonical list of affected columns
    lives in models/sources.yml on each table's description.

    Usage:
        {{ wnba_coalesce_variant('fg3m') }} as fg3m
#}

{% macro wnba_coalesce_variant(column_name) %}
    coalesce({{ column_name }}::float, {{ column_name }}__v_double)
{% endmacro %}


{#
    wnba_parse_minutes -- minutes-played text to a numeric value.

    PLAYER_STATS.MIN is TEXT: whole minutes ('23', '0') today, with 'MM:SS'
    a plausible future shape. Handles both; anything else returns NULL so it
    surfaces in tests rather than aggregating as zero.
#}

{% macro wnba_parse_minutes(column_name) %}

    case
        when {{ column_name }} rlike '^[0-9]+$'
            then try_cast({{ column_name }} as float)
        when {{ column_name }} rlike '^[0-9]+:[0-5][0-9]$'
            then try_cast(split_part({{ column_name }}, ':', 1) as float)
               + try_cast(split_part({{ column_name }}, ':', 2) as float) / 60
    end

{% endmacro %}
