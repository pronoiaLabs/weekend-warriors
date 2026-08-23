{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_players -- the nflverse players id table, one row per gsis_id.

    The all-history crosswalk (25k rows): gsis_id is the key every other
    nflverse table joins on, and the row carries the other vendors' ids
    (espn_id, pfr_id, pff_id, otc_id, esb_id, smart_id) plus the headshot URL.
    Team abbreviations are nflverse's own (LA, WAS); nflverse_team_abbr keeps
    them and team_abbreviation maps them onto dim_team's vocabulary for joins.

    Vendor-prefixed because BallDontLie already owns `players` in RAW.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_players') }}

)

select
    gsis_id,
    esb_id,
    smart_id,
    nfl_id::string                                  as nfl_id,
    try_to_number(espn_id::string)::string          as espn_id,
    pfr_id,
    pff_id,
    otc_id,

    display_name,
    common_first_name,
    first_name,
    last_name,
    football_name,
    short_name,
    suffix,

    position,
    position_group,
    ngs_position,
    ngs_position_group,
    pff_position,

    latest_team                                     as nflverse_team_abbr,
    case latest_team
        when 'LA'  then 'LAR'
        when 'WAS' then 'WSH'
        else latest_team
    end                                             as team_abbreviation,
    status,
    ngs_status,
    ngs_status_short_description,
    pff_status,

    try_to_number(jersey_number::string)            as jersey_number,
    height::float                                   as height_inches,
    weight::float                                   as weight_lbs,
    try_to_date(birth_date::string)                 as birth_date,
    college_name,
    college_conference,
    rookie_season::int                              as rookie_season,
    last_season::int                                as last_season,
    years_of_experience::int                        as years_of_experience,
    draft_year::int                                 as draft_year,
    draft_round::int                                as draft_round,
    draft_pick::int                                 as draft_pick,
    draft_team,

    headshot                                        as headshot_url,

    to_timestamp_tz(_dlt_load_id::float::number)    as loaded_at

from source
where gsis_id is not null
