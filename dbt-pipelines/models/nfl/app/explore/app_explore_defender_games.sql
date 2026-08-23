{{
    config(
        materialized='table'
    )
}}

/*
    app_explore_defender_games -- the Explorer's defensive player-game sheet.
    One row per defender game (app_player_defense_weeks), curated columns.
*/

select
    player_game_key                                     as row_id,
    player_name,
    position,
    position_group,
    team_label                                          as team,
    opponent_label                                      as opponent,
    is_home,
    season,
    season_type_name                                    as season_type,
    week,
    game_date,
    team_result,
    team_points,
    opponent_points,
    total_tackles,
    solo_tackles,
    assisted_tackles,
    tackles_for_loss,
    sacks,
    qb_hits,
    passes_defended,
    interceptions,
    interception_yards,
    interception_touchdowns,
    fumbles_recovered,
    fumbles_touchdowns,
    takeaways,
    defensive_touchdowns
from {{ ref('app_player_defense_weeks') }}
