{{
    config(
        materialized='table'
    )
}}

/*
    app_prop_line_history -- a prop's movement from first offer to close.

    Grain: game x player x sportsbook x prop type x snapshot
    (fact_player_prop_snapshot), with the player's identity and the game's teams
    attached. The prop edge page draws the movement from this; the prop board's
    line_movement is the first-to-last summary of the same path.
*/

select
    s.player_prop_snapshot_key                          as app_prop_line_history_key,
    s.game_player_vendor_prop_key,
    s.game_key,
    s.game_id,
    s.player_key,
    s.player_id,
    p.full_name                                         as player_name,
    p.position_abbreviation                             as position,
    s.season,
    s.week,
    s.season_type,
    s.season_type_name,
    s.game_date,
    g.game_datetime_et,
    g.is_completed,
    s.home_team_key,
    ht.team_abbreviation                                as home_team_label,
    s.away_team_key,
    at.team_abbreviation                                as away_team_label,
    s.vendor,
    s.prop_type,
    s.market_type,
    m.stat_key,
    m.stat_label,
    s.snapshot_number,
    s.snapshots_before_kickoff,
    s.is_opening,
    s.is_closing,
    s.snapshot_observed_at,
    s.prev_snapshot_observed_at,
    s.minutes_before_kickoff,
    round(s.minutes_before_kickoff / 60.0, 1)           as hours_before_kickoff,
    s.line_value,
    s.market_odds,
    s.over_odds,
    s.under_odds,
    s.line_value_change,
    s.market_odds_change,
    s.over_odds_change,
    s.under_odds_change,
    s.line_value - first_value(s.line_value) over (
        partition by s.game_player_vendor_prop_key order by s.snapshot_number
    )                                                   as line_value_since_open
from {{ ref('fact_player_prop_snapshot') }} s
inner join {{ ref('dim_game') }} g
    on g.game_key = s.game_key
left join {{ ref('dim_player') }} p
    on p.player_key = s.player_key
left join {{ ref('dim_team') }} ht
    on ht.team_key = s.home_team_key
left join {{ ref('dim_team') }} at
    on at.team_key = s.away_team_key
left join {{ ref('seed_nfl_prop_stat_map') }} m
    on m.prop_type = s.prop_type
