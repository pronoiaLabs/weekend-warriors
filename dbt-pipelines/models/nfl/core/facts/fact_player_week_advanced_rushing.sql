{{
    config(
        materialized='table'
    )
}}

/*
    fact_player_week_advanced_rushing -- Next Gen rushing, weekly.
    Grain: player x season x week x postseason.

    Excludes the week = 0 season totals, which live in
    fact_player_season_advanced_rushing. See
    fact_player_week_advanced_passing for the full rationale.

    NO game_key -- this source has no game_id.

    The measures worth knowing: rush_yards_over_expected isolates the runner's
    contribution from his blocking, and percent_attempts_gte_eight_defenders
    shows how loaded the box was against him.
*/

select * exclude (is_season_total)

from {{ ref('stg_nfl__advanced_rushing') }}
where not is_season_total
