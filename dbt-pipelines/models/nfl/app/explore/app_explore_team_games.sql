{{
    config(
        materialized='table'
    )
}}

/*
    app_explore_team_games -- the Explorer's team-game sheet.

    One row per team game, the box score from both sides and the result, no
    line (the game lines sheet has those per book). app_team_weeks carries one
    row per book; this takes the first row per team game, which is identical
    across books on every column kept here.
*/

select
    team_game_key                                       as row_id,
    team_label                                          as team,
    team_name,
    conference,
    division,
    opponent_label                                      as opponent,
    is_home,
    season,
    season_type_name                                    as season_type,
    week,
    game_date,
    result,
    went_to_overtime,
    points_for,
    points_against,
    point_margin,
    total_points,
    points_q1, points_q2, points_q3, points_q4, points_ot,
    first_downs,
    total_yards,
    plays,
    yards_per_play,
    net_passing_yards,
    passing_completions,
    passing_attempts,
    rushing_yards,
    rushing_attempts,
    third_down_conversions,
    third_down_attempts,
    third_down_pct,
    fourth_down_conversions,
    fourth_down_attempts,
    red_zone_scores,
    red_zone_attempts,
    red_zone_pct,
    total_drives,
    possession_time_seconds,
    turnovers,
    takeaways,
    turnover_margin,
    fumbles_lost,
    interceptions_thrown,
    sacks_allowed,
    sacks_recorded,
    penalties,
    penalty_yards,
    opp_total_yards,
    opp_yards_per_play,
    opp_net_passing_yards,
    opp_rushing_yards,
    opp_third_down_conversions,
    opp_third_down_attempts,
    opp_red_zone_scores,
    opp_red_zone_attempts
from {{ ref('app_team_weeks') }}
qualify row_number() over (partition by team_game_key order by vendor nulls first) = 1
