{{
    config(
        materialized='table'
    )
}}

/*
    fact_player_season_advanced_passing -- Next Gen passing, season totals.
    Grain: player x season x postseason.

    These are the week = 0 rows from the source. They are NOT a rollup of the
    weekly fact and cannot be recomputed from it: 50,025 season-total attempts
    against 47,392 summed across weeks 1-18, with 83 of 138 players differing.
    The source's own totals are the authoritative full-season line, so they are
    preserved as their own fact at their own grain rather than dropped or derived.

    week and season_week_key are excluded because they are meaningless here --
    week is the literal 0 sentinel and season_week_key is NULL by construction.
*/

select * exclude (is_season_total, week, season_week_key)

from {{ ref('stg_nfl__advanced_passing') }}
where is_season_total
