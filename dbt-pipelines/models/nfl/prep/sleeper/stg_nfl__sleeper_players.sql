{{ config(materialized='view') }}

{#
    stg_nfl__sleeper_players -- Sleeper's daily player dump.
    Grain: player (sleeper_player_id); replaced once a day, so this is
    CURRENT state, not history. 12k rows including 32 DEF team rows.

    The live signal BallDontLie lacks: injury_status and practice
    participation as the app shows them, depth-chart position and order, and
    search_rank (Sleeper's own relevance ordering, a free popularity proxy).
    The VARIANT columns pass through for audit, as stg_nfl__news_articles
    does. Ids are sparse (gsis_id on ~18%): bridge_player_ids is the join
    path, not these columns.
#}

with source as (

    select * from {{ source('nfl_raw', 'sleeper_players') }}

)

select
    player_id                                           as sleeper_player_id,
    full_name,
    first_name,
    last_name,
    search_full_name,
    "ACTIVE"                                            as is_active,
    status,
    position,
    fantasy_positions,
    team,
    try_to_number(number::string)                       as jersey_number,
    depth_chart_position,
    depth_chart_order,

    injury_status,
    injury_body_part,
    injury_notes,
    practice_participation,
    practice_description,
    to_timestamp_tz(news_updated::string)               as news_updated_at,

    -- ::varchar first: these land typed NUMBER from JSON, and TRY_TO_NUMBER
    -- rejects a NUMBER argument (found on the first build).
    try_to_number(search_rank::varchar)                 as search_rank,
    try_to_number(years_exp::varchar)                   as years_experience,
    try_to_number(age::varchar)                         as age,
    try_to_date(birth_date::string)                     as birth_date,
    height,
    weight,
    college,
    high_school,

    gsis_id,
    try_to_number(espn_id::string)::string              as espn_id,
    kalshi_id,
    sportradar_id,
    try_to_number(yahoo_id::string)::string             as yahoo_id,
    try_to_number(rotowire_id::string)::string          as rotowire_id,
    oddsjam_id,

    metadata,
    competitions,

    fetched_at,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
