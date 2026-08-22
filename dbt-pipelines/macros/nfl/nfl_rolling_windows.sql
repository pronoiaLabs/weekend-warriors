{#
    nfl_rolling_windows -- 1-preceding frames for FEATURES marts.

    _std  season-to-date excluding the current row
    _l3   last 3 eligible rows excluding current
    _l5   last 5 eligible rows excluding current

    The caller must already have excluded preseason from the ordered set.
    Conditional iff() in the expression does not remove rows from the frame.
#}

{% macro nfl_rolling_frame(suffix) -%}
    {%- if suffix == 'std' -%}
        unbounded preceding and 1 preceding
    {%- elif suffix == 'l3' -%}
        3 preceding and 1 preceding
    {%- elif suffix == 'l5' -%}
        5 preceding and 1 preceding
    {%- else -%}
        {{ exceptions.raise_compiler_error("nfl_rolling_frame: unknown suffix " ~ suffix) }}
    {%- endif -%}
{%- endmacro %}


{% macro nfl_roll(expr, partition_cols, suffix) -%}
sum({{ expr }}) over (
    partition by {{ partition_cols }}
    order by game_datetime, game_key
    rows between {{ nfl_rolling_frame(suffix) }}
)
{%- endmacro %}


{% macro nfl_rolling_suffixes() -%}
    {{ return(['std', 'l3', 'l5']) }}
{%- endmacro %}
