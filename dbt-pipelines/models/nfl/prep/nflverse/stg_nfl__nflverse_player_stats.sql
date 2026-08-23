{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_player_stats -- nflverse's 150-column player week.
    Grain: player (gsis) x season x season_type x week.

    The richest thing in the nflverse set: usage shares (target_share,
    air_yards_share, wopr), EPA by phase, CPOE, and both fantasy scorings,
    none of which BallDontLie carries. A bye week simply has no row; game_id
    is nflverse's <season>_<week>_<away>_<home> and joins through
    bridge_game_ids. Parquet arrives typed, so no casts: this list is the
    contract, and a column added upstream stays invisible until named here.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_player_stats') }}

)

select
    -- grain and identity
    player_id                                           as gsis_id,
    season,
    season_type,
    week,
    game_id                                             as nflverse_game_id,
    player_name,
    player_display_name,
    position,
    position_group,
    team,
    opponent_team,
    headshot_url,

    -- passing
    completions,
    attempts,
    passing_yards,
    passing_tds,
    passing_interceptions,
    sacks_suffered,
    sack_yards_lost,
    sack_fumbles,
    sack_fumbles_lost,
    passing_air_yards,
    passing_yards_after_catch,
    passing_first_downs,
    passing_epa,
    passing_cpoe,
    passing_2pt_conversions,
    pacr,
    passing_10,
    passing_16,
    passing_20,
    passing_40,

    -- rushing
    carries,
    rushing_yards,
    rushing_tds,
    rushing_fumbles,
    rushing_fumbles_lost,
    rushing_first_downs,
    rushing_epa,
    rushing_2pt_conversions,
    rushing_10,
    rushing_12,
    rushing_20,
    rushing_40,

    -- receiving and usage
    receptions,
    targets,
    receiving_yards,
    receiving_tds,
    receiving_fumbles,
    receiving_fumbles_lost,
    receiving_air_yards,
    receiving_yards_after_catch,
    receiving_first_downs,
    receiving_epa,
    receiving_2pt_conversions,
    receiving_10,
    receiving_16,
    receiving_20,
    receiving_40,
    racr,
    target_share,
    air_yards_share,
    wopr,

    -- defense
    def_tackles_solo,
    def_tackles_with_assist,
    def_tackle_assists,
    def_tackles_for_loss,
    def_tackles_for_loss_yards,
    def_fumbles_forced,
    def_sacks,
    def_sack_yards,
    def_qb_hits,
    def_interceptions,
    def_interception_yards,
    def_pass_defended,
    def_tds,
    def_fumbles,
    def_safeties,
    def_punt_blocks,
    def_pat_blocks,
    def_fg_blocks,
    def_2pt_atts,
    def_2pt_made,

    -- fumbles, penalties, misc
    misc_yards,
    fumble_recovery_own,
    fumble_recovery_yards_own,
    fumble_recovery_opp,
    fumble_recovery_yards_opp,
    fumble_recovery_tds,
    penalties,
    penalty_yards,
    fumbles_forced_by_opp,
    fumbles_not_forced,
    fumbles_out_of_bounds,
    fumbles_total,
    fumbles_lost_total,

    -- returns
    punt_returns,
    punt_return_yards,
    kickoff_returns,
    kickoff_return_yards,
    special_teams_tds,

    -- kicking
    fg_made,
    fg_att,
    fg_missed,
    fg_blocked,
    fg_long,
    fg_pct,
    fg_made_0_19,
    fg_made_20_29,
    fg_made_30_39,
    fg_made_40_49,
    fg_made_50_59,
    fg_made_60x,
    fg_missed_0_19,
    fg_missed_20_29,
    fg_missed_30_39,
    fg_missed_40_49,
    fg_missed_50_59,
    fg_missed_60x,
    fg_made_distance,
    fg_missed_distance,
    fg_blocked_distance,
    fg_made_list,
    fg_missed_list,
    fg_blocked_list,
    pat_made,
    pat_att,
    pat_missed,
    pat_blocked,
    pat_pct,
    gwfg_made,
    gwfg_att,
    gwfg_missed,
    gwfg_blocked,
    gwfg_distance,

    -- punting
    pt_att,
    pt_blocked,
    pt_yards,
    pt_inside_20,
    pt_out_of_bounds,
    pt_downed,
    pt_touchback,
    pt_fair_caught,
    pt_returned,
    pt_return_yards,
    pt_return_tds,
    pt_net_yards,
    pt_long,

    -- fantasy
    fantasy_points,
    fantasy_points_ppr,

    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at

from source
where player_id is not null
