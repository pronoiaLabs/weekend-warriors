{{
    config(
        materialized='table'
    )
}}

/*
    app_line_history -- the market page's movement chart: every pregame line
    change for a game at a book, with the teams attached.

    Grain: game x sportsbook x snapshot (fact_game_betting_odds_snapshot). Rows
    carry the game identity the page already knows from the slate, so the chart
    needs no join, and the change from the previous snapshot so a movement
    table is one filter away.
*/

select
    s.game_odds_snapshot_key                            as app_line_history_key,
    s.game_vendor_odds_key,
    s.game_key,
    s.game_id,
    s.season,
    s.week,
    s.season_type,
    s.season_type_name,
    s.game_date,
    g.game_datetime_et,
    g.is_completed,
    s.home_team_key,
    ht.team_abbreviation                                as home_team_label,
    ht.team_full_name                                   as home_team_name,
    s.away_team_key,
    at.team_abbreviation                                as away_team_label,
    at.team_full_name                                   as away_team_name,
    s.vendor,
    s.snapshot_number,
    s.snapshots_before_kickoff,
    s.is_opening,
    s.is_closing,
    s.snapshot_observed_at,
    s.prev_snapshot_observed_at,
    s.minutes_before_kickoff,
    round(s.minutes_before_kickoff / 60.0, 1)           as hours_before_kickoff,
    s.home_spread,
    s.home_spread_odds,
    s.away_spread,
    s.away_spread_odds,
    s.home_moneyline_odds,
    s.away_moneyline_odds,
    s.total_line,
    s.over_odds,
    s.under_odds,
    s.home_spread_change,
    s.total_line_change,
    s.home_moneyline_odds_change,
    s.away_moneyline_odds_change,
    s.home_spread - first_value(s.home_spread) over (
        partition by s.game_vendor_odds_key order by s.snapshot_number
    )                                                   as home_spread_since_open,
    s.total_line - first_value(s.total_line) over (
        partition by s.game_vendor_odds_key order by s.snapshot_number
    )                                                   as total_line_since_open
from {{ ref('fact_game_betting_odds_snapshot') }} s
inner join {{ ref('dim_game') }} g
    on g.game_key = s.game_key
left join {{ ref('dim_team') }} ht
    on ht.team_key = s.home_team_key
left join {{ ref('dim_team') }} at
    on at.team_key = s.away_team_key
