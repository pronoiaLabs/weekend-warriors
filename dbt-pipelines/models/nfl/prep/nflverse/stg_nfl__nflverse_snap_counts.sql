{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_snap_counts -- participation, one row per player per game.
    Grain: pfr_player x game.

    Keyed on Pro Football Reference ids, not gsis: the crosswalk runs through
    stg_nfl__nflverse_players.pfr_id. game_id is nflverse's, so it joins
    through bridge_game_ids; game_type is nflverse's calendar (REG, WC, DIV,
    CON, SB), not the season_type integer.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_snap_counts') }}

)

select
    game_id                                             as nflverse_game_id,
    pfr_game_id,
    pfr_player_id,
    player                                              as player_name,
    position,
    team,
    opponent,
    season,
    game_type,
    week,
    offense_snaps,
    offense_pct,
    defense_snaps,
    defense_pct,
    st_snaps,
    st_pct,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
where pfr_player_id is not null
