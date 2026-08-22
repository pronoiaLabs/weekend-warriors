{#
    nfl_parse_record -- pull a component out of an NFL record string.

    The standings source stores split records as text: "11-6" or, when there was
    a tie, "11-6-1". Wins and losses are always present; ties are only in the
    third position when non-zero, so a missing third part means zero ties, not
    unknown.

    Usage:
        {{ nfl_parse_record('home_record', 'wins') }}
#}

{% macro nfl_parse_record(column_name, part) %}

    {%- if part == 'wins' -%}
        try_cast(split_part({{ column_name }}, '-', 1) as int)
    {%- elif part == 'losses' -%}
        try_cast(split_part({{ column_name }}, '-', 2) as int)
    {%- elif part == 'ties' -%}
        coalesce(try_cast(nullif(split_part({{ column_name }}, '-', 3), '') as int), 0)
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "nfl_parse_record: part must be one of wins/losses/ties, got '" ~ part ~ "'"
        ) }}
    {%- endif -%}

{% endmacro %}


{#
    nfl_win_pct -- NFL winning percentage.

    A tie counts as half a win, so the formula is (W + 0.5T) / (W + L + T),
    not W / (W + L). Returns NULL rather than erroring when no games have been
    played, since a 0-0-0 team has no defined percentage.
#}

{% macro nfl_win_pct(wins_column, losses_column, ties_column) %}

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
    nfl_normalize_player_name -- fold a player name into a comparable key.

    News writes "D.J. Wonnum" and "Kenneth Walker"; the roster has "DJ Wonnum" and
    "Kenneth Walker III". Uppercase, drop a generational suffix (JR, SR, II, III,
    IV), strip every character that is not a letter, digit or space, collapse
    whitespace, and NULL an empty result. Applied to BOTH sides of a name join and
    never stored on dim_player, whose grain and tests stay untouched.

    Measured on the first day of news (86 mentions): 78 resolved uniquely on this
    key alone, none were ambiguous, and the misses were non-players (team names,
    coaches, retired legends) plus two nicknames the alias seed covers.

    Regex escapes are doubled ('\\s') because dbt renders the file before Snowflake
    sees it; stg_nfl__players.sql uses the same convention.

    Usage:
        {{ nfl_normalize_player_name('player_name') }}
#}

{% macro nfl_normalize_player_name(column_name) %}

    nullif(
        trim(
            regexp_replace(
                regexp_replace(
                    regexp_replace(upper({{ column_name }}), '\\s+(JR\\.?|SR\\.?|II|III|IV)$', ''),
                    '[^A-Z0-9 ]', ''
                ),
                '\\s+', ' '
            )
        ),
        ''
    )

{% endmacro %}
