{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_nextgen_rushing -- NFL Next Gen Stats, rushing, weekly.
    Grain: player (gsis) x season x season_type x week, plus week-0 season
    totals (is_season_total), as in stg_nfl__nflverse_nextgen_passing.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_nextgen_rushing') }}

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
    efficiency,
    percent_attempts_gte_eight_defenders,
    avg_time_to_los,
    rush_attempts,
    rush_yards,
    avg_rush_yards,
    rush_touchdowns,
    expected_rush_yards,
    rush_yards_over_expected,
    rush_yards_over_expected_per_att,
    rush_pct_over_expected,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
where player_gsis_id is not null
