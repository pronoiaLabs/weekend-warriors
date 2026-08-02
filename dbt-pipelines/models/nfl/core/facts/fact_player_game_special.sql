{{
    config(
        materialized='table'
    )
}}

/*
    fact_player_game_special -- kicking, punting and returns.
    Grain: player x game. ~7,700 rows, the smallest of the three phase facts.

    See fact_player_game_offense for the phase-split rationale and the
    deliberate cross-fact key overlap.

    Three sub-disciplines share this fact because they are all special teams and
    each is small on its own: place kicking, punting, and return work. The
    has_kicking / has_punting / has_returns flags separate them, since a kicker
    and a return specialist have nothing in common measure-wise.

    kicking_total_points comes from the source's total_points column, which is
    only populated for kickers -- it is not a player's total points scored in
    general, hence the rename in prep.
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
                                                        as has_returns

from special s
inner join games g
    on s.game_key = g.game_key
