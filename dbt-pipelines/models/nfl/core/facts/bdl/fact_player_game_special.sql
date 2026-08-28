{{ config(materialized='table') }}

/*
    fact_player_game_special -- kicking, punting and returns, all vendors.
    Grain: player x game. ~7,700 rows, the smallest of the three phase facts.
    BallDontLie is the anchor; nflverse fills its gaps (distance bands, the
    full PAT line, punt placement) where the bridges find the player-week.

    See fact_player_game_offense for the phase-split rationale and the
    deliberate cross-fact key overlap.

    Three sub-disciplines share this fact because they are all special teams and
    each is small on its own: place kicking, punting, and return work. The
    has_kicking / has_punting / has_returns flags separate them, since a kicker
    and a return specialist have nothing in common measure-wise.

    kicking_total_points comes from the source's total_points column, which is
    only populated for kickers -- it is not a player's total points scored in
    general, hence the rename in prep.

    VENDOR BLOCKS. Same bridge path as the offense fact (see its header). The
    PAT block is the headline: BallDontLie publishes extra_points_made only
    (its play stream has no XP plays at all, see dim_play_type), so attempts,
    misses, blocks and pct exist only here. The nflverse return counters keep
    the vendor prefix because BallDontLie publishes the same stats under its
    own names above. Sleeper's kicking columns populate only for actual
    kickers, about a quarter of matched rows. Measured Aug 2026, excluding
    preseason: 99.7% regular season / 100% postseason carry the nflverse
    block -- the best of the three player facts, since kickers, punters and
    returners are all named players; Sleeper 78.3% / 83.0%.
*/

with stats as (

    select * from {{ ref('stg_nfl__player_stats') }}

),

games as (

    select
        game_key,
        date_key,
        season_week_key,
        season,
        week,
        season_type,
        is_postseason
    from {{ ref('dim_game') }}

),

special as (

    select *
    from stats
    where coalesce(
              field_goal_attempts,
              field_goals_made,
              extra_points_made,
              punts,
              kick_returns,
              punt_returns
          ) is not null

),

-- One row per player_key; see fact_player_game_offense for why the qualify.
bridge as (

    select player_key, gsis_id, pfr_id, sleeper_player_id
    from {{ ref('bridge_player_ids') }}
    where player_key is not null
    qualify row_number() over (partition by player_key order by gsis_id) = 1

),

game_bridge as (

    select game_key, nflverse_game_id, nflverse_week, season, week,
           season_type, is_postseason
    from {{ ref('bridge_game_ids') }}

),

nflverse as (

    select * from {{ ref('stg_nfl__nflverse_player_stats') }}

),

snaps as (

    select pfr_player_id, nflverse_game_id, st_snaps, st_pct
    from {{ ref('stg_nfl__nflverse_snap_counts') }}

),

sleeper as (

    -- No is_team_defense filter: the DEF team rows carry the club abbreviation
    -- as their id and can never match the bridge's numeric sleeper ids, while
    -- prep's length-based flag also catches real veterans with short ids
    -- (id 96, 167, ...) whose weeks belong here.
    select * from {{ ref('stg_nfl__sleeper_stats') }}

)

select
    -- keys
    s.player_game_key,
    s.game_key,
    s.game_id,
    s.player_key,
    s.player_id,
    s.team_key,
    s.team_id,
    g.date_key,
    g.season_week_key,

    -- context
    g.season,
    g.week,
    g.season_type,
    g.is_postseason,

    -- ---------------------------------------------------------------
    -- place kicking
    -- ---------------------------------------------------------------
    s.field_goal_attempts,
    s.field_goals_made,
    s.field_goal_pct,
    s.long_field_goal_made,
    s.extra_points_made,
    s.kicking_total_points,

    -- ---------------------------------------------------------------
    -- punting
    -- ---------------------------------------------------------------
    s.punts,
    s.punt_yards,
    s.gross_avg_punt_yards,
    s.touchbacks,
    s.punts_inside_20,
    s.long_punt,

    -- ---------------------------------------------------------------
    -- returns
    -- ---------------------------------------------------------------
    s.kick_returns,
    s.kick_return_yards,
    s.yards_per_kick_return,
    s.long_kick_return,
    s.kick_return_touchdowns,

    s.punt_returns,
    s.punt_return_yards,
    s.yards_per_punt_return,
    s.long_punt_return,
    s.punt_return_touchdowns,

    -- ---------------------------------------------------------------
    -- derived roll-ups across both return types
    -- ---------------------------------------------------------------
    coalesce(s.kick_returns, 0) + coalesce(s.punt_returns, 0)
                                                        as total_returns,
    coalesce(s.kick_return_yards, 0) + coalesce(s.punt_return_yards, 0)
                                                        as total_return_yards,
    coalesce(s.kick_return_touchdowns, 0) + coalesce(s.punt_return_touchdowns, 0)
                                                        as total_return_touchdowns,

    -- sub-discipline flags: a kicker and a returner share no measures
    (coalesce(s.field_goal_attempts, s.extra_points_made) is not null)
                                                        as has_kicking,
    (s.punts is not null)                               as has_punting,
    (coalesce(s.kick_returns, s.punt_returns) is not null)
                                                        as has_returns,

    -- ---------------------------------------------------------------
    -- nflverse: field goals by distance band, made and missed, plus the
    -- per-kick distance list and game-winning attempts
    -- ---------------------------------------------------------------
    nv.fg_made_0_19,
    nv.fg_made_20_29,
    nv.fg_made_30_39,
    nv.fg_made_40_49,
    nv.fg_made_50_59,
    nv.fg_made_60x,
    nv.fg_missed_0_19,
    nv.fg_missed_20_29,
    nv.fg_missed_30_39,
    nv.fg_missed_40_49,
    nv.fg_missed_50_59,
    nv.fg_missed_60x,
    nv.fg_made_list,
    nv.gwfg_att,
    nv.gwfg_made,

    -- nflverse: the full PAT line (BDL carries made only, see header)
    nv.pat_att,
    nv.pat_made,
    nv.pat_missed,
    nv.pat_blocked,
    nv.pat_pct,

    -- nflverse: punt placement and outcome detail
    nv.pt_att,
    nv.pt_blocked,
    nv.pt_yards,
    nv.pt_inside_20,
    nv.pt_out_of_bounds,
    nv.pt_downed,
    nv.pt_touchback,
    nv.pt_fair_caught,
    nv.pt_returned,
    nv.pt_return_yards,
    nv.pt_return_tds,
    nv.pt_net_yards,
    nv.pt_long,

    -- nflverse: return detail, vendor-prefixed because BDL publishes the
    -- same counters under its own names above
    nv.punt_returns                                     as nflverse_punt_returns,
    nv.punt_return_yards                                as nflverse_punt_return_yards,
    nv.kickoff_returns                                  as nflverse_kickoff_returns,
    nv.kickoff_return_yards                             as nflverse_kickoff_return_yards,
    nv.special_teams_tds,

    -- nflverse: snaps, via the pfr crosswalk on the bridge
    sn.st_snaps,
    sn.st_pct,

    (nv.gsis_id is not null)                            as has_nflverse,

    -- ---------------------------------------------------------------
    -- Sleeper: kicking and snap share (kicking columns populate for actual
    -- kickers only)
    -- ---------------------------------------------------------------
    sl.fgm,
    sl.fga,
    sl.xpm,
    sl.xpa,
    sl.st_snp,
    sl.tm_st_snp,

    (sl.sleeper_player_id is not null)                  as has_sleeper

from special s
inner join games g
    on s.game_key = g.game_key
left join bridge b
    on b.player_key = s.player_key
left join game_bridge gb
    on gb.game_key = s.game_key
left join nflverse nv
    on  nv.gsis_id = b.gsis_id
    and nv.nflverse_game_id = gb.nflverse_game_id
left join snaps sn
    on  sn.pfr_player_id = b.pfr_id
    and sn.nflverse_game_id = gb.nflverse_game_id
left join sleeper sl
    on  sl.sleeper_player_id = b.sleeper_player_id
    and sl.season = gb.season
    and case sl.season_type
            when 'regular' then gb.season_type = 2 and sl.week = gb.week
            when 'post'    then gb.is_postseason and sl.week + 18 = gb.nflverse_week
            when 'pre'     then gb.season_type = 1 and sl.week = gb.week
        end
