{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_nextgen_receiving -- NFL Next Gen Stats, receiving, weekly.
    Grain: player (gsis) x season x season_type x week, plus week-0 season
    totals (is_season_total), as in stg_nfl__nflverse_nextgen_passing.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_nextgen_receiving') }}

)

select
    player_gsis_id                                      as gsis_id,
    season,
    season_type,
    week,
    week = 0                                            as is_season_total,
    player_display_name,
    player_position,
    team_abbr,
    avg_cushion,
    avg_separation,
    avg_intended_air_yards,
    percent_share_of_intended_air_yards,
    receptions,
    targets,
    catch_percentage,
    yards,
    rec_touchdowns,
    avg_yac,
    avg_expected_yac,
    avg_yac_above_expectation,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
where player_gsis_id is not null
