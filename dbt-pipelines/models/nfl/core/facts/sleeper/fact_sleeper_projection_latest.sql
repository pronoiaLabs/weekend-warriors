{{ config(materialized='table') }}

/*
    fact_sleeper_projection_latest -- the projection that stood at kickoff.
    Grain: player x game, exactly one row: the latest strictly-pre-kickoff
    snapshot from fact_sleeper_projection_snapshot.

    This is the projection the props semantic view relates to (a prop row is
    game x player x vendor x prop_type, so the join from props is N:1 onto
    this table and cannot fan out). The snapshot fact keeps every movement;
    this table answers the one question the market comparison needs -- "what
    did Sleeper project when the line closed" -- without asking the view to
    re-derive the selection.

    Rows are dropped, not NULLed, when they cannot serve that question:
    post-kickoff revisions, snapshots whose kickoff is unresolved
    (is_pre_kickoff NULL -- Sleeper's clock and the schedule disagreed, so
    "pre-kickoff" is unknowable), and rows without a bridged game or player.
    fgm/fga are not carried: no kicker prop exists in seed_nfl_prop_stat_map.
*/

select
    projection_snapshot_key,
    player_key,
    gsis_id,
    sleeper_player_id,
    game_key,
    game_id,
    team_key,
    season,
    season_type,
    week,
    snapshot_number,
    snapshots_total,
    fetched_at          as projection_as_of,
    pts_ppr,
    pts_half_ppr,
    pts_std,
    pts_ppr_change,
    rec_tgt,
    rec,
    rec_yd,
    rec_td,
    rush_att,
    rush_yd,
    rush_td,
    pass_att,
    pass_yd,
    pass_td,
    pass_int,
    adp_dd_ppr,
    pos_adp_dd_ppr
from {{ ref('fact_sleeper_projection_snapshot') }}
where is_pre_kickoff
  and game_key is not null
  and player_key is not null
qualify row_number() over (
    partition by player_key, game_key
    order by fetched_at desc
) = 1
