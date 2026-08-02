{{
    config(
        materialized='table'
    )
}}

/*
    fact_player_week_advanced_receiving -- Next Gen receiving, weekly.
    Grain: player x season x week x postseason. The largest of the three Next Gen
    facts, since far more players catch passes than throw or carry them.

    Excludes the week = 0 season totals, which live in
    fact_player_season_advanced_receiving. See
    fact_player_week_advanced_passing for the full rationale.

    NO game_key -- this source has no game_id.

    The measures worth knowing: avg_separation is the gap from the defender at
    the catch point, avg_cushion is how far off he lined up, and
    percent_share_of_intended_air_yards shows the receiver's role in the offence.
*/

select * exclude (is_season_total)

from {{ ref('stg_nfl__advanced_receiving') }}
where not is_season_total
