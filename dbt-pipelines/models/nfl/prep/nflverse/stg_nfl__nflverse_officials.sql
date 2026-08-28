{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_officials -- officiating crew assignments.
    Grain: nfl_old_game_id x official_id.

    The RAW table speaks only the league's own ids (measured): game_id is the
    old YYYYMMDDNN shape and game_key a numeric league key -- NEITHER is the
    2024_01_DEN_SEA id the rest of the nflverse tree joins on. game_key is
    deliberately dropped (keeping it invites a join against the BDL game_key
    that would silently match nothing); nflverse_game_id is minted here by
    translating old_game_id through the pbp file, which carries both shapes
    1:1. It is NULL for seasons outside the loaded pbp window (officials go
    back to 2015, pbp to 2023) -- those rows cannot anchor to a game we model
    and downstream joins through bridge_game_ids skip them.

    position is the crew role, spelled out in full ('Referee', 'Umpire',
    'Back Judge' ... -- NOT the R/U/BJ codes); the referee is the head
    official that dim_game denormalizes, exactly one per game.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_officials') }}

),

-- old id -> nflverse id, observed from pbp (1:1, measured over 855 games)
game_ids as (

    select distinct
        old_game_id,
        nflverse_game_id
    from {{ ref('stg_nfl__nflverse_pbp') }}
    where old_game_id is not null

)

select
    s.game_id::string                                   as nfl_old_game_id,
    g.nflverse_game_id,
    s.official_id,
    s.official_name,
    s.position                                          as official_position,
    try_to_number(s.jersey_number::varchar)             as jersey_number,
    s.season,
    s.season_type                                       as nflverse_season_type,
    s.week,
    to_timestamp_tz(s._dlt_load_id::float::number)      as loaded_at
from source s
left join game_ids g
    on g.old_game_id = s.game_id::string
where s.official_id is not null
