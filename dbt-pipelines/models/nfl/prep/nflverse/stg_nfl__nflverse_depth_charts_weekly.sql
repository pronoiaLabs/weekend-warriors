{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_depth_charts_weekly -- the weekly chart, 2023 to 2024.
    Grain: season x week x team x formation x position x rank x player; the
    row hash (row_id) minted at ingestion is the only clean key, because two
    players can legitimately share formation, position and rank (measured:
    12,289 such collisions on the player-free key).

    The file the league published weekly through 2024, replaced by the daily
    snapshots in 2025 (stg_nfl__nflverse_depth_charts). formation here is the
    coarse unit (Offense, Defense, Special Teams) and depth_position the
    specific slot (LCB, RG); depth_team is the rank.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_depth_charts_weekly') }}

)

select
    row_id,
    season,
    week,
    game_type,
    club_code                                           as team,
    formation,
    position,
    coalesce(depth_position, position)                  as depth_position,
    try_to_number(depth_team::varchar)                  as depth_rank,
    gsis_id,
    elias_id,
    try_to_number(jersey_number::string)                as jersey_number,
    full_name,
    first_name,
    last_name,
    football_name,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
