{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_injuries -- the league's official injury report.
    Grain: season x season_type x week x team x player (gsis).

    Different animal from BallDontLie's player_injuries (a vendor's rolling
    status): these are the practice and game designations clubs must file.
    report_status is the game designation (Out, Doubtful, Questionable);
    practice_status the participation line. game_type is nflverse's calendar;
    the numeric season_type rides beside it from the source.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_injuries') }}

)

select
    season,
    season_type,
    game_type,
    week,
    team,
    gsis_id,
    position,
    full_name,
    first_name,
    last_name,
    report_status,
    report_primary_injury,
    report_secondary_injury,
    practice_status,
    practice_primary_injury,
    practice_secondary_injury,
    date_modified,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
where gsis_id is not null
