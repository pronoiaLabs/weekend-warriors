{{
    config(
        materialized='table'
    )
}}

/*
    app_explore_game_lines -- the Explorer's game-line sheet.

    One row per game and book with a closing line (app_game_slate rows that
    carry a vendor): the opener, the close, the movement, implied totals and
    devig probabilities, and the score and results once played.
*/

select
    game_vendor_odds_key                                as row_id,
    season,
    season_type_name                                    as season_type,
    week,
    game_date,
    kickoff_slot_et,
    away_team_label                                     as away_team,
    home_team_label                                     as home_team,
    stadium_name,
    roof,
    vendor,
    home_spread,
    home_spread_odds,
    away_spread,
    away_spread_odds,
    total_line,
    over_odds,
    under_odds,
    home_moneyline_odds,
    away_moneyline_odds,
    opening_home_spread,
    opening_total_line,
    home_spread_movement,
    total_line_movement,
    implied_home_team_total,
    implied_away_team_total,
    home_moneyline_devig_probability,
    away_moneyline_devig_probability,
    is_completed,
    away_score,
    home_score,
    home_spread_result,
    total_result,
    kickoff_temp_f,
    wind_mph,
    precip_in
from {{ ref('app_game_slate') }}
where vendor is not null
