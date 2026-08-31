{{
    config(
        materialized='table'
    )
}}

/*
    app_player_weeks -- a player's season, one row per game played.

    Grain: player x game (the grain of fact_player_game_offense). The box score
    with the player's identity, the team he played for that game, the opponent,
    the game result from his team's side, fantasy points at both books, and
    running counts within the season type (games_to_date, fantasy_to_date).
    Running counts order by week (one game per week within a season type):
    the fact's date_key is a surrogate, not a calendar order, and ordering by
    it scrambled games_to_date. Offensive players only, completed games only.
    The long companion,
    app_player_week_stats, is the same rows one stat at a time with trailing
    and prior-season comparisons for charts and the year-over-year columns.

    The vendor blocks ride through un-coalesced: NULL on target_share, the
    EPA columns or ppr_points means the vendor did not match that player-game
    (has_nflverse / has_sleeper say which), never zero. Canonical PPR is
    nflverse fantasy_points_ppr (99% of player-games); Sleeper's pts_ppr and
    its PER-WEEK pos_rank_ppr ride under sleeper_* names and must never be
    read as season figures. snap_pct prefers nflverse offense_pct with
    Sleeper's off_snap_share standing in (the prop board's convention);
    off_snaps / team_off_snaps are the Sleeper ratio-of-sums components a
    multi-game snap share must divide, and team_targets is the BDL-derived
    denominator that lets a season target share be a ratio of sums.
*/

with offense as (

    select * from {{ ref('fact_player_game_offense') }}

),

players as (

    select * from {{ ref('dim_player') }}

),

games as (

    select * from {{ ref('dim_game') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

team_games as (

    select
        game_key,
        team_key,
        is_win,
        is_loss,
        is_tie,
        points_scored,
        points_allowed
    from {{ ref('fact_team_game_offense') }}

),

running as (

    select
        player_game_key,
        row_number() over (
            partition by player_key, season, season_type order by week, game_key
        )                                               as games_to_date,
        sum(fanduel_points) over (
            partition by player_key, season, season_type order by week, game_key
            rows between unbounded preceding and current row
        )                                               as fanduel_points_to_date,
        sum(draftkings_points) over (
            partition by player_key, season, season_type order by week, game_key
            rows between unbounded preceding and current row
        )                                               as draftkings_points_to_date,
        sum(scrimmage_yards) over (
            partition by player_key, season, season_type order by week, game_key
            rows between unbounded preceding and current row
        )                                               as scrimmage_yards_to_date
    from offense

)

select
    o.player_game_key                                   as app_player_weeks_key,
    o.player_game_key,
    o.game_key,
    o.game_id,
    o.player_key,
    o.player_id,
    p.full_name                                         as player_name,
    p.position_abbreviation                             as position,
    p.position_name,
    p.position_group,
    o.team_key,
    o.team_id,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    iff(o.team_key = g.home_team_key, g.away_team_key, g.home_team_key)
                                                        as opponent_team_key,
    ot.team_abbreviation                                as opponent_label,
    ot.team_full_name                                   as opponent_name,
    o.team_key = g.home_team_key                        as is_home,
    o.season,
    o.week,
    o.season_type,
    g.season_type_name,
    o.is_postseason,
    g.game_date,
    g.game_datetime_et,
    g.is_completed,
    case when tg.is_win then 'W' when tg.is_loss then 'L' when tg.is_tie then 'T' end
                                                        as team_result,
    tg.points_scored                                    as team_points,
    tg.points_allowed                                   as opponent_points,
    r.games_to_date,
    o.passing_attempts,
    o.passing_completions,
    o.passing_yards,
    o.yards_per_pass_attempt,
    o.passing_touchdowns,
    o.passing_interceptions,
    o.times_sacked,
    o.sack_yards_lost,
    o.qb_rating,
    o.qbr,
    o.rushing_attempts,
    o.rushing_yards,
    o.yards_per_rush_attempt,
    o.rushing_touchdowns,
    o.long_rushing,
    o.receiving_targets,
    o.receptions,
    o.receiving_yards,
    o.yards_per_reception,
    o.receiving_touchdowns,
    o.long_reception,
    o.fumbles,
    o.fumbles_lost,
    o.scrimmage_yards,
    o.scrimmage_touchdowns,
    coalesce(o.rushing_touchdowns, 0) + coalesce(o.receiving_touchdowns, 0)
                                                        as scoring_touchdowns,
    o.touches,
    o.has_passing,
    o.has_rushing,
    o.has_receiving,
    o.two_point_conversions,
    o.two_point_conversions_thrown,
    o.target_share,
    o.air_yards_share,
    o.receiving_air_yards,
    sum(o.receiving_targets) over (partition by o.game_key, o.team_key)
                                                        as team_targets,
    -- clamped at 1: Sleeper's team snap total can undercount by a snap and
    -- put an every-down player a hair over (62 of 61, measured)
    least(coalesce(o.offense_pct, o.off_snap_share), 1) as snap_pct,
    o.offense_pct,
    o.off_snp                                           as off_snaps,
    o.tm_off_snp                                        as team_off_snaps,
    o.passing_epa,
    o.rushing_epa,
    o.receiving_epa,
    o.fantasy_points_ppr                                as ppr_points,
    o.pts_ppr                                           as sleeper_ppr_points,
    o.pos_rank_ppr                                      as sleeper_ppr_pos_rank,
    o.has_nflverse,
    o.has_sleeper,
    o.fanduel_points,
    o.draftkings_points,
    r.fanduel_points_to_date,
    r.draftkings_points_to_date,
    r.scrimmage_yards_to_date
from offense o
inner join players p
    on p.player_key = o.player_key
inner join games g
    on g.game_key = o.game_key
inner join running r
    on r.player_game_key = o.player_game_key
left join teams t
    on t.team_key = o.team_key
left join teams ot
    on ot.team_key = iff(o.team_key = g.home_team_key, g.away_team_key, g.home_team_key)
left join team_games tg
    on tg.game_key = o.game_key
   and tg.team_key = o.team_key
