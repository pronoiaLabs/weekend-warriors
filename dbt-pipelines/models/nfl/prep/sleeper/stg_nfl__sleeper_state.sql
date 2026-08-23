{{ config(materialized='view') }}

{#
    stg_nfl__sleeper_state -- Sleeper's week clock, one row per pipeline run.
    Grain: fetched_at.

    A log of what /v1/state/nfl said each time a Sleeper pipeline ran: the
    season, week and season_type every other sleeper_* row was stamped with.
    Useful for auditing when Sleeper's clock rolled relative to ours.
#}

with source as (

    select * from {{ source('nfl_raw', 'sleeper_state') }}

)

select
    fetched_at,
    season::int                                         as season,
    season_type,
    week::int                                           as week,
    display_week::int                                   as display_week,
    leg::int                                            as leg,
    season_has_scores,
    league_season::int                                  as league_season,
    previous_season::int                                as previous_season,
    try_to_date(season_start_date::string)              as season_start_date,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
