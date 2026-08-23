{{ config(materialized='view') }}

{#
    stg_nfl__sleeper_trending -- the 24h add/drop leaderboard, appended
    every 6 hours. Grain: fetched_at x direction x player.

    count is how many Sleeper leagues added or dropped the player in the
    trailing lookback window; rank is his position on that fetch's board
    (the API caps the board at 100 per direction). The crowd's reaction to
    news, hours ahead of any official designation.
#}

with source as (

    select * from {{ source('nfl_raw', 'sleeper_trending') }}

)

select
    fetched_at,
    direction,
    player_id                                           as sleeper_player_id,
    count                                               as move_count,
    rank                                                as board_rank,
    lookback_hours,
    state_season,
    state_week,
    state_season_type,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
