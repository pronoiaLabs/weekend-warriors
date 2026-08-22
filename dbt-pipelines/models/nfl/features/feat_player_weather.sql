{{
    config(
        materialized='table'
    )
}}

/*
    feat_player_weather -- player x game. Matchup weather joined to trailing
    role. Never archive / ERA5 / RAW hourly.

    Products only:
      pass_volume_in_wind      team_pass_share_l5  x wind
      targets_in_wind          team_target_share_l5 x wind
      rush_share_in_wind       team_rush_share_l5   x wind
      pass_volume_in_cold      team_pass_share_l5  x max(0, 50 - temp)
      ball_security_in_precip  touches_l5          x I(precip >= 0.05)
*/

with players as (

    select * from {{ ref('feat_player_game_rolling') }}

),

matchup as (

    select
        game_key,
        weather_temp_f,
        weather_wind_mph,
        weather_gust_mph,
        weather_precip_in,
        weather_code,
        weather_hours_before_kickoff,
        weather_product,
        is_weather_relevant,
        elevation_m,
        roof,
        surface
    from {{ ref('feat_game_matchup') }}

)

select
    p.player_game_key,
    p.game_key,
    p.game_id,
    p.player_key,
    p.player_id,
    p.team_key,
    p.season,
    p.week,
    p.is_home,
    p.is_completed,

    m.is_weather_relevant,
    m.weather_temp_f,
    m.weather_wind_mph,
    m.weather_gust_mph,
    m.weather_precip_in,
    m.weather_code,
    m.weather_hours_before_kickoff,
    m.weather_product,
    m.elevation_m,
    m.roof,
    m.surface,

    p.team_pass_share_l5 * m.weather_wind_mph as pass_volume_in_wind,
    p.team_target_share_l5 * m.weather_wind_mph as targets_in_wind,
    p.team_rush_share_l5 * m.weather_wind_mph as rush_share_in_wind,
    p.team_pass_share_l5 * greatest(0, 50 - m.weather_temp_f) as pass_volume_in_cold,
    p.touches_l5 * iff(coalesce(m.weather_precip_in, 0) >= 0.05, 1, 0) as ball_security_in_precip

from players p
inner join matchup m
    on p.game_key = m.game_key
