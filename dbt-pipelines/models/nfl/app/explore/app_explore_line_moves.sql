{{
    config(
        materialized='table'
    )
}}

/*
    app_explore_line_moves -- the Explorer's line-movement sheet. One row per
    pregame line change for a game at a book (app_line_history).
*/

select
    app_line_history_key                                as row_id,
    season,
    season_type_name                                    as season_type,
    week,
    game_date,
    away_team_label                                     as away_team,
    home_team_label                                     as home_team,
    vendor,
    snapshot_number,
    snapshots_before_kickoff,
    is_opening,
    is_closing,
    snapshot_observed_at,
    hours_before_kickoff,
    home_spread,
    home_spread_odds,
    away_spread_odds,
    total_line,
    over_odds,
    under_odds,
    home_moneyline_odds,
    away_moneyline_odds,
    home_spread_change,
    total_line_change,
    home_spread_since_open,
    total_line_since_open
from {{ ref('app_line_history') }}
