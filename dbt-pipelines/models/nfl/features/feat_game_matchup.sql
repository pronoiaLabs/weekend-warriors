{{
    config(
        materialized='table'
    )
}}

/*
    feat_game_matchup -- one row per dim_game.

    home_* / away_* are that side's feat_team_game_rolling snapshot for this
    game. Weather is coalesce(forecast, hist_forecast) and never archive.
    close_* is one vendor (var odds_vendor, default caesars) and is not a
    label. Outcomes are label_* only and null on unplayed games.
*/

{% set windows = nfl_rolling_suffixes() %}
{% set roll_cols = [
    'n_games_played',
    'has_box_score_window',
    'has_opp_box_score_window',
    'has_player_defense_window',
    'points_per_game',
    'margin_per_game',
    'win_rate',
    'yards_per_play',
    'yards_per_pass',
    'yards_per_rush',
    'pass_rate',
    'seconds_per_play',
    'plays_per_game',
    'pass_att_per_game',
    'rush_att_per_game',
    'net_pass_per_game',
    'rush_yds_per_game',
    'first_downs_per_game',
    'third_down_rate',
    'fourth_down_rate',
    'red_zone_td_rate',
    'drives_per_game',
    'sack_rate_taken',
    'sack_yards_per_game',
    'turnover_rate',
    'int_rate',
    'fumbles_lost_per_game',
    'penalty_yards_per_game',
    'opp_points_per_game',
    'opp_yards_per_play',
    'opp_yards_per_pass',
    'opp_yards_per_rush',
    'opp_pass_rate',
    'opp_third_down_rate',
    'opp_red_zone_td_rate',
    'opp_first_downs_per_game',
    'takeaways_per_drive',
    'sacks_recorded_per_game',
    'qb_hits_per_game',
    'tfl_per_game',
    'passes_defended_per_game',
    'interceptions_per_game',
    'def_td_team_box_per_game',
    'def_td_player_rollup_per_game',
    'defenders_with_stats_per_game',
    'passing_attempts',
    'rushing_attempts',
    'net_passing_yards',
    'rushing_yards',
    'points_scored',
    'takeaways',
] %}

with games as (

    select * from {{ ref('dim_game') }}

),

rolling as (

    select * from {{ ref('feat_team_game_rolling') }}

),

stadiums as (

    select * from {{ ref('dim_stadium') }}

),

weather as (

    select
        game_key,
        product,
        is_weather_relevant,
        kickoff_temp_f,
        wind_mph,
        gust_mph,
        wind_dir_deg,
        precip_in,
        weather_code,
        hours_before_kickoff
    from {{ ref('fact_game_weather') }}
    where product in ('forecast', 'hist_forecast')
    qualify row_number() over (
        partition by game_key
        order by iff(product = 'forecast', 1, 2)
    ) = 1

),

closing as (

    select
        game_key,
        vendor,
        home_spread,
        total_line,
        home_moneyline_odds,
        away_moneyline_odds,
        implied_home_team_total,
        implied_away_team_total
    from {{ ref('fact_game_betting_odds_closing') }}
    where vendor = '{{ var("odds_vendor", "caesars") }}'

),

home_off as (

    select * from rolling where is_home

),

away_off as (

    select * from rolling where not is_home

),

home_result as (

    select
        game_key,
        points_scored as home_points,
        points_allowed as away_points,
        net_passing_yards as home_net_pass,
        rushing_yards as home_rush
    from {{ ref('fact_team_game_offense') }}
    where is_home

),

away_result as (

    select
        game_key,
        net_passing_yards as away_net_pass,
        rushing_yards as away_rush
    from {{ ref('fact_team_game_offense') }}
    where not is_home

)

select
    g.game_key,
    g.game_id,
    g.game_datetime,
    g.game_date,
    g.date_key,
    g.season,
    g.week,
    g.season_type,
    g.season_type_name,
    g.is_postseason,
    g.season_week_key,
    g.is_completed,
    g.home_team_key,
    g.away_team_key,
    g.stadium_key,

    h.rest_days as home_rest_days,
    a.rest_days as away_rest_days,
    h.is_short_week as home_is_short_week,
    a.is_short_week as away_is_short_week,

    {% for col in roll_cols %}
    {% for w in windows %}
    h.{{ col }}_{{ w }} as home_{{ col }}_{{ w }},
    a.{{ col }}_{{ w }} as away_{{ col }}_{{ w }},
    {% endfor %}
    {% endfor %}

    st.display_name as stadium_display_name,
    st.roof,
    st.surface,
    st.elevation_m,
    st.timezone as stadium_timezone,
    st.is_weather_relevant,
    st.is_international,

    iff(coalesce(st.is_weather_relevant, false), wx.kickoff_temp_f, null) as weather_temp_f,
    iff(coalesce(st.is_weather_relevant, false), wx.wind_mph, null) as weather_wind_mph,
    iff(coalesce(st.is_weather_relevant, false), wx.gust_mph, null) as weather_gust_mph,
    iff(coalesce(st.is_weather_relevant, false), wx.wind_dir_deg, null) as weather_wind_dir_deg,
    iff(coalesce(st.is_weather_relevant, false), wx.precip_in, null) as weather_precip_in,
    iff(coalesce(st.is_weather_relevant, false), wx.weather_code, null) as weather_code,
    wx.hours_before_kickoff as weather_hours_before_kickoff,
    wx.product as weather_product,

    c.vendor as close_vendor,
    c.home_spread as close_spread,
    c.total_line as close_total,
    c.home_moneyline_odds as close_home_ml,
    c.away_moneyline_odds as close_away_ml,
    c.implied_home_team_total as close_implied_home_total,
    c.implied_away_team_total as close_implied_away_total,

    iff(g.is_completed, hr.home_points, null) as label_home_points,
    iff(g.is_completed, hr.away_points, null) as label_away_points,
    iff(g.is_completed, hr.home_points + hr.away_points, null) as label_total,
    iff(g.is_completed, hr.home_points - hr.away_points, null) as label_home_margin,
    iff(g.is_completed, hr.home_net_pass, null) as label_home_net_pass,
    iff(g.is_completed, ar.away_net_pass, null) as label_away_net_pass,
    iff(g.is_completed, hr.home_rush, null) as label_home_rush,
    iff(g.is_completed, ar.away_rush, null) as label_away_rush

from games g
inner join home_off h
    on g.game_key = h.game_key
inner join away_off a
    on g.game_key = a.game_key
left join stadiums st
    on g.stadium_key = st.stadium_key
left join weather wx
    on g.game_key = wx.game_key
left join closing c
    on g.game_key = c.game_key
left join home_result hr
    on g.game_key = hr.game_key
left join away_result ar
    on g.game_key = ar.game_key
