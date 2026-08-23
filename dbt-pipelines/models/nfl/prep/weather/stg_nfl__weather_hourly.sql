{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__weather_hourly -- stadium x hour x product.

    Open-Meteo is requested with timezone=UTC, so hour_at joins
    date_trunc('hour', dim_game.game_datetime) without a local conversion.
    product is archive (ERA5), forecast (live), or hist_forecast (what was
    knowable before kickoff).
*/

with source as (

    select * from {{ source('nfl_raw', 'weather_hourly') }}

)

select
    stadium_id,
    hour_at::timestamp_tz                               as hour_at,
    product,
    temperature_f::float                                as temperature_f,
    wind_mph::float                                     as wind_mph,
    gust_mph::float                                     as gust_mph,
    wind_dir_deg::float                                 as wind_dir_deg,
    precip_in::float                                    as precip_in,
    weather_code::number                                as weather_code,
    elevation_m::float                                  as elevation_m,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
