{{ config(materialized='view') }}

{#
    stg_nfl__sleeper_stats -- Sleeper's weekly actuals with fantasy points.
    Grain: player x season x season_type x week (merged at ingestion, so one
    row per player-week, latest fetch wins).

    The draw is what the box score cannot give: Sleeper's three fantasy
    scorings of the ACTUAL week (pts_std, pts_half_ppr, pts_ppr), positional
    ranks per scoring, and snap counts with team totals beside them. Core
    counting stats ride along for reconciliation; the ~280-column longtail
    stays in RAW.
#}

with source as (

    select * from {{ source('nfl_raw', 'sleeper_stats') }}

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
    "DATE"                                              as game_date,

    pts_std,
    pts_half_ppr,
    pts_ppr,
    pos_rank_std,
    pos_rank_half_ppr,
    pos_rank_ppr,

    gp,
    gs,
    gms_active,
    off_snp,
    def_snp,
    st_snp,
    tm_off_snp,
    tm_def_snp,
    tm_st_snp,

    pass_att,
    pass_cmp,
    pass_yd,
    pass_td,
    pass_int,
    pass_sack,
    pass_rtg,

    rush_att,
    rush_yd,
    rush_td,
    rush_fd,

    rec_tgt,
    rec,
    rec_yd,
    rec_td,
    rec_fd,
    rec_drop,
    rec_air_yd,

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
    idp_qb_hit,

    pts_allow,
    yds_allow,
    def_td,

    to_timestamp_tz(last_modified::string)              as last_modified_at,
    fetched_at,
    state_season,
    state_week,
    state_season_type,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
