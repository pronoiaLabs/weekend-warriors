{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_nextgen_passing -- NFL Next Gen Stats, passing, weekly.
    Grain: player (gsis) x season x season_type x week, PLUS one season-total
    row per player at week 0 (is_season_total), same convention as the
    BallDontLie advanced stats: facts exclude it, season marts keep it.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_nextgen_passing') }}

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
    avg_time_to_throw,
    avg_completed_air_yards,
    avg_intended_air_yards,
    avg_air_yards_differential,
    aggressiveness,
    max_completed_air_distance,
    avg_air_yards_to_sticks,
    attempts,
    pass_yards,
    pass_touchdowns,
    interceptions,
    passer_rating,
    completions,
    completion_percentage,
    expected_completion_percentage,
    completion_percentage_above_expectation,
    avg_air_distance,
    max_air_distance,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
where player_gsis_id is not null
