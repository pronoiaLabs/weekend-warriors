{{ config(materialized='table') }}

/*
    fact_game_weather -- kickoff-hour conditions. Grain: game x product.

    hour_at is UTC, matching dim_game.game_datetime. Domes keep a row;
    is_weather_relevant gates whether wind/temp should move a total.
*/

with games as (

    select
        game_key,
        game_id,
        game_datetime,
        date_key,
        season,
        week,
        season_type_name,
        season_week_key,
        home_team_key,
        away_team_key,
        stadium_key,
        is_completed,
        date_trunc('hour', game_datetime) as kickoff_hour_utc
    from {{ ref('dim_game') }}

),

stadiums as (

    select
        stadium_key,
        stadium_id,
        is_weather_relevant
    from {{ ref('dim_stadium') }}

),

hourly as (

    select * from {{ ref('stg_nfl__weather_hourly') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['g.game_key', 'w.product']) }} as game_weather_key,
    g.game_key,
    g.game_id,
    g.date_key,
    g.season,
    g.week,
    g.season_type_name,
    g.season_week_key,
    g.home_team_key,
    g.away_team_key,
    g.stadium_key,
    g.is_completed,
    s.is_weather_relevant,
    w.product,
    w.hour_at,
    w.temperature_f as kickoff_temp_f,
    w.wind_mph,
    w.gust_mph,
    w.wind_dir_deg,
    w.precip_in,
    w.weather_code,
    datediff('hour', w.loaded_at, g.game_datetime) as hours_before_kickoff
from games g
inner join stadiums s
    on g.stadium_key = s.stadium_key
inner join hourly w
    on  w.stadium_id = s.stadium_id
    and w.hour_at = g.kickoff_hour_utc
