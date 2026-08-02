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
