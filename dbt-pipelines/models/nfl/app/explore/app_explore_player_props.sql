{{
    config(
        materialized='table'
    )
}}

/*
    app_explore_player_props -- the Explorer's prop sheet.

    One row per player prop at a book (app_game_prop_board): the line and
    price, the player's trailing form against it, the opponent's rank for the
    stat, and the outcome once played.
*/

select
    app_game_prop_board_key                             as row_id,
    player_name,
    position,
    team_label                                          as team,
    opponent_label                                      as opponent,
    is_home,
    season,
    season_type_name                                    as season_type,
    week,
    game_date,
    vendor,
    prop_type,
    market_type,
    stat_label                                          as stat,
    line_value,
    opening_line_value,
    line_movement,
    over_odds,
    under_odds,
    market_odds,
    trailing_games,
    trailing_avg,
    trailing_over_line,
    trailing_hit_rate,
    gap_to_line,
    games_played_to_date,
    stat_avg_to_date,
    hit_rate_over_line,
    opponent_allowed_per_game,
    opponent_allowed_rank,
    opponent_allowed_season,
    is_completed,
    actual_value,
    outcome
from {{ ref('app_game_prop_board') }}
