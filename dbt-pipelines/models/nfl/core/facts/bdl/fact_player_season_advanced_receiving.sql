{{
    config(
        materialized='table'
    )
}}

/*
    fact_player_season_advanced_receiving -- Next Gen receiving, season totals.
    Grain: player x season x postseason.

    The week = 0 rows: the source's authoritative full-season line, not a rollup
    of the weekly fact. See fact_player_season_advanced_passing for why these are
    kept separate rather than derived.
*/

select * exclude (is_season_total, week, season_week_key)

from {{ ref('stg_nfl__advanced_receiving') }}
where is_season_total
