{{ config(materialized='view') }}

{#
    stg_nfl__sleeper_projections -- Sleeper's weekly projections, as fetched.
    Grain: player x season x season_type x week x fetched_at. Appended dated
    snapshots: their movement is the point, and fact_sleeper_projection_snapshot
    collapses the runs where nothing moved.

    Curated to the fantasy-relevant measures; the full 121 columns stay in
    RAW for anything exotic. DEF team rows ride along (player_id is the team
    abbreviation); pts_* are Sleeper's own scoring of its projection.
#}

with source as (

    select * from {{ source('nfl_raw', 'sleeper_projections') }}

)

select
    player_id                                           as sleeper_player_id,
    length(player_id) <= 3                              as is_team_defense,
    season::int                                         as season,
    season_type,
    week::int                                           as week,
    team,
    opponent,
    game_id                                             as sleeper_game_id,
    company,
    "DATE"                                              as game_date,

    pts_std,
    pts_half_ppr,
    pts_ppr,

    adp_dd_ppr,
    pos_adp_dd_ppr,

    pass_att,
    pass_cmp,
    pass_yd,
    pass_td,
    pass_int,
    pass_2pt,
    pass_fd,
    pass_sack,

    rush_att,
    rush_yd,
    rush_td,
    rush_fd,
    rush_2pt,

    rec_tgt,
    rec,
    rec_yd,
    rec_td,
    rec_fd,
    rec_2pt,

    fum,
    fum_lost,

    fgm,
    fga,
    xpm,
    xpa,

    idp_tkl,
    idp_tkl_solo,
    idp_tkl_ast,
    idp_sack,
    idp_int,
    idp_ff,
    idp_fum_rec,
    idp_pass_def,

    pts_allow,
    yds_allow,
    def_td,
    sack,
    "INT"                                               as def_int,
    ff,
    fum_rec,
    safe                                                as safeties,
    blk_kick,

    to_timestamp_tz(last_modified::string)              as last_modified_at,
    fetched_at,
    state_season,
    state_week,
    state_season_type,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
