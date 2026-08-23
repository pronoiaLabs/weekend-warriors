{{
    config(
        materialized='table'
    )
}}

/*
    app_explore_player_games -- the Explorer's offensive player-game sheet.

    One row per player game (app_player_weeks), with the page plumbing left
    out: no surrogate keys beyond row_id, no running *_to_date columns. The
    column set is the sheet's contract; the page mart can grow without the
    sheet changing.
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
    passing_attempts,
    passing_completions,
    passing_yards,
    passing_touchdowns,
    passing_interceptions,
    times_sacked,
    qb_rating,
    qbr,
    rushing_attempts,
    rushing_yards,
    rushing_touchdowns,
    long_rushing,
    receiving_targets,
    receptions,
    receiving_yards,
    receiving_touchdowns,
    long_reception,
    fumbles,
    fumbles_lost,
    scrimmage_yards,
    scrimmage_touchdowns,
    scoring_touchdowns,
    touches,
    two_point_conversions,
    fanduel_points,
    draftkings_points
from {{ ref('app_player_weeks') }}
