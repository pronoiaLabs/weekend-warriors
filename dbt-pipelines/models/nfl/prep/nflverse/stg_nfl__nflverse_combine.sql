{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_combine -- NFL Combine results, 2000 on.
    Grain: combine appearance (season x player_name x pos -- unique, measured
    8,968 rows; effectively one row per player, since a player attends once).

    pfr_id is the crosswalk to nflverse players, but it is imperfect at the
    source: NULL on 1,531 rows (mostly older seasons) and 17 ids sit on two
    rows each -- same-name DIFFERENT players wrongly sharing an id upstream
    ('Chris Brown 2001 OT' / 'Chris Brown 2003 RB'), so it is not this view's
    key. ht arrives as feet-inches text ('6-2', clean, measured) and is
    converted to inches to match the rest of the warehouse.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_combine') }}

)

select
    season,
    pfr_id,
    cfb_id,
    player_name,
    pos                                                 as position,
    school,

    draft_year::int                                     as draft_year,
    draft_team,
    draft_round::int                                    as draft_round,
    draft_ovr::int                                      as draft_overall,

    -- athletic testing. ht is '6-2' text; NULL stays NULL through the split.
    (split_part(ht, '-', 1)::int * 12
        + split_part(ht, '-', 2)::int)::float           as height_inches,
    wt::float                                           as weight_lbs,
    forty,
    bench::int                                          as bench,
    vertical,
    broad_jump::int                                     as broad_jump,
    cone,
    shuttle,

    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
