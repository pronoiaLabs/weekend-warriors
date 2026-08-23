{{
    config(
        materialized='table'
    )
}}

/*
    fact_player_week_advanced_passing -- Next Gen passing, weekly.
    Grain: player x season x week x postseason.

    Excludes week 0, which is a SEASON TOTAL rather than a week and does not
    reconcile with the sum of the weekly rows. Those live in
    fact_player_season_advanced_passing. Mixing them would double-count an entire
    season -- see stg_nfl__advanced_passing for the full explanation.

    NO game_key. This source has no game_id, so the fact conforms to dim_player
    and dim_season_week but cannot be joined to dim_game. "Time to throw in
    Week 3" works; "against Dallas" does not.

    The column list comes from the prep view, which already curated it -- exclude
    is used so a new Next Gen measure appearing upstream flows through instead of
    being silently dropped here.
*/

select * exclude (is_season_total)

from {{ ref('stg_nfl__advanced_passing') }}
where not is_season_total
