{#
    ncaaf_parse_record -- pull a component out of an NCAAF record string.

    Record strings arrive as text: "11-2" today, "11-2-1" when there was a
    tie. College football abolished ties in 1996, but the standings and
    rankings sources reach back far enough in principle that the third
    position is a data condition, not a caller bug -- so this mirrors
    nfl_parse_record (tie-capable), not the WNBA variant.

    Usage:
        {{ ncaaf_parse_record('home_record', 'wins') }}
#}

{% macro ncaaf_parse_record(column_name, part) %}

    {%- if part == 'wins' -%}
        try_cast(split_part({{ column_name }}, '-', 1) as int)
    {%- elif part == 'losses' -%}
        try_cast(split_part({{ column_name }}, '-', 2) as int)
    {%- elif part == 'ties' -%}
        coalesce(try_cast(nullif(split_part({{ column_name }}, '-', 3), '') as int), 0)
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "ncaaf_parse_record: part must be one of wins/losses/ties, got '" ~ part ~ "'"
        ) }}
    {%- endif -%}

{% endmacro %}


{#
    ncaaf_win_pct -- winning percentage with the tie term: (W + 0.5T) / games.

    Same shape as nfl_win_pct (see ncaaf_parse_record for why ties exist
    here). Returns NULL when no games have been played -- the standings
    source publishes 0-0 preseason slates with NULL wins, and a 0-0 team has
    no defined percentage.
#}

{% macro ncaaf_win_pct(wins_column, losses_column, ties_column) %}

    case
        when coalesce({{ wins_column }}, 0)
           + coalesce({{ losses_column }}, 0)
           + coalesce({{ ties_column }}, 0) > 0
        then (coalesce({{ wins_column }}, 0) + 0.5 * coalesce({{ ties_column }}, 0))
             / (coalesce({{ wins_column }}, 0)
              + coalesce({{ losses_column }}, 0)
              + coalesce({{ ties_column }}, 0))
    end

{% endmacro %}


{#
    ncaaf_coalesce_variant -- fold a dlt variant-split twin column back into
    one. Identical mechanics to wnba_coalesce_variant; duplicated per sport
    deliberately so each sport's macro directory is self-contained and a
    sport can be lifted out of the project whole.

    The canonical twin list (7 columns across 4 tables) lives in
    models/sources.yml on the ncaaf_raw table descriptions.

    Usage:
        {{ ncaaf_coalesce_variant('passing_qbr') }} as passing_qbr
#}

{% macro ncaaf_coalesce_variant(column_name) %}
    coalesce({{ column_name }}::float, {{ column_name }}__v_double)
{% endmacro %}


{#
    ncaaf_parse_efficiency -- split a 'made-attempts' efficiency string.

    TEAM_STATS stores third- and fourth-down efficiency as TEXT like '5-12'
    (5 conversions on 12 attempts). Splitting on '-' gives both halves; the
    derived rate belongs to the caller so the two integers stay reusable.
    Anything that does not parse returns NULL and surfaces in tests rather
    than aggregating as zero.

    Usage:
        {{ ncaaf_parse_efficiency('third_down_efficiency', 'made') }}
#}

{% macro ncaaf_parse_efficiency(column_name, part) %}

    {%- if part == 'made' -%}
        try_cast(split_part({{ column_name }}, '-', 1) as int)
    {%- elif part == 'attempts' -%}
        try_cast(split_part({{ column_name }}, '-', 2) as int)
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "ncaaf_parse_efficiency: part must be one of made/attempts, got '" ~ part ~ "'"
        ) }}
    {%- endif -%}

{% endmacro %}


{#
    ncaaf_parse_clock_minutes -- 'MM:SS' possession text to numeric minutes.

    TEAM_STATS.POSSESSION_TIME is TEXT like '31:24'. Returns fractional
    minutes (31.4), NULL for anything that does not match, so a new upstream
    shape fails a test instead of summing as zero.
#}

{% macro ncaaf_parse_clock_minutes(column_name) %}

    case
        when {{ column_name }} rlike '^[0-9]+:[0-5][0-9]$'
            then try_cast(split_part({{ column_name }}, ':', 1) as float)
               + try_cast(split_part({{ column_name }}, ':', 2) as float) / 60
    end

{% endmacro %}
