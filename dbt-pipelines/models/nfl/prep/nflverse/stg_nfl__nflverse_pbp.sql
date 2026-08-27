{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_pbp -- curated slice of nflverse play-by-play.
    Grain: nflverse play (nflverse_game_id x play_id).

    The RAW table is 372 columns; this view keeps the ones the warehouse
    actually models, in four groups: identity/situation (the play-match keys
    fact_play grafts on), the analytics measures (EPA/WPA/success and the
    passing model outputs), the call/formation flags that define situational
    splits, and drive bookkeeping. Every downstream nflverse pbp read comes
    through here -- this view ends the direct RAW reads that bridge_game_ids
    and the team EPA columns used to make.

    Clock columns: `time` is the display clock (MM:SS text);
    quarter_seconds_remaining is the matching key against BallDontLie's clock.
    There is no two-minute-warning column in the file -- derive two-minute
    situations as half_seconds_remaining <= 120.

    season_type here is nflverse's vocabulary ('REG'/'POST' text), not the
    numeric season_type the BDL tree carries; it is prefixed to say so.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_pbp') }}

)

select
    -- identity. old_game_id is the league's YYYYMMDDNN id -- the only shape
    -- NFLVERSE_OFFICIALS speaks (measured), so it is the translation key that
    -- lets the officials view mint a real nflverse_game_id.
    game_id                                             as nflverse_game_id,
    old_game_id::string                                 as old_game_id,
    play_id::number                                     as play_id,
    season,
    week,
    season_type                                         as nflverse_season_type,
    try_to_date(game_date::string)                      as game_date,
    home_team,
    away_team,
    posteam,
    defteam,
    posteam_type,

    -- situation (the play-match keys)
    qtr::number                                         as qtr,
    time                                                as clock,
    quarter_seconds_remaining::number                   as quarter_seconds_remaining,
    half_seconds_remaining::number                      as half_seconds_remaining,
    game_seconds_remaining::number                      as game_seconds_remaining,
    down::number                                        as down,
    ydstogo::number                                     as ydstogo,
    yardline_100::number                                as yardline_100,
    score_differential::number                          as score_differential,

    -- what was called and what happened
    play_type,
    play_type_nfl,
    "DESC"                                              as play_description,
    yards_gained::number                                as yards_gained,
    first_down::number                                  as first_down,
    qb_dropback::number                                 as qb_dropback,
    qb_scramble::number                                 as qb_scramble,
    qb_kneel::number                                    as qb_kneel,
    qb_spike::number                                    as qb_spike,
    rush_attempt::number                                as rush_attempt,
    pass_attempt::number                                as pass_attempt,
    -- nflfastR's play-classification pair, distinct from the attempt columns:
    -- pass includes sacks and scrambles (a dropback), rush excludes scrambles.
    -- The team EPA fold aggregates on these, so they must come through as-is.
    pass::number                                        as pass,
    rush::number                                        as rush,
    shotgun::number                                     as shotgun,
    no_huddle::number                                   as no_huddle,

    -- analytics measures (the graft columns)
    epa,
    wpa,
    success::number                                     as success,
    cpoe,
    cp,
    xpass,
    pass_oe,
    air_yards::number                                   as air_yards,
    yards_after_catch::number                           as yards_after_catch,
    qb_epa,

    -- drive bookkeeping
    drive::number                                       as drive,
    series::number                                      as series,
    fixed_drive::number                                 as fixed_drive,

    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
