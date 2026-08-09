{{
    config(
        materialized='table'
    )
}}

/*
    fact_team_game -- one row per team per COMPLETED game. Grain: team x game.

    Two rows per completed game, exactly. Scheduled games are filtered out at
    the games CTE: a fact row asserts "this team played this game and here is
    what happened", and an unplayed game has no such row. Without the filter,
    every scheduled game becomes two NULL-score rows that inflate game counts
    and averages (and would mint fake ties if the provider ever writes 0-0
    placeholders). The full slate including unplayed games lives on dim_game,
    which carries is_completed for exactly this reason.

    This is the unpivot of stg_nfl__games (which stores home and away side by
    side) into the standard sports-star shape, with the team box score joined on.
    Every row answers "how did THIS team do in THIS game", carrying
    opponent_team_key so opponent analysis needs no self-join, and
    points_scored / points_allowed rather than home/away scores so that records
    and splits are plain aggregations.

    The unpivot is a UNION ALL of two selects over the same completed-games
    set, not a join, so it cannot fan out: exactly two rows per game by
    construction.

    Box score coverage: team_stats trails the fact by a handful -- some games have no
    team_stats. The join is a LEFT JOIN, so those four team-game rows exist with
    the result populated and every box-score measure NULL. Losing the games
    entirely would be worse than carrying the NULLs.

    Season scope is all three season types. season_type is on dim_game and
    dim_season_week; filter there rather than assuming regular season.
*/

with games as (

    select * from {{ ref('stg_nfl__games') }}
    where is_completed          -- scheduled games have no fact rows, see header

),

-- ---------------------------------------------------------------------------
-- Unpivot: one select per side, unioned. Two rows per game, guaranteed.
-- ---------------------------------------------------------------------------
home_side as (

    select
        game_key,
        game_id,
        game_date,
        season,
        week,
        season_type,
        is_postseason,
        went_to_overtime,

        home_team_key           as team_key,
        home_team_id            as team_id,
        away_team_key           as opponent_team_key,
        away_team_id            as opponent_team_id,
        true                    as is_home,

        home_team_score         as points_scored,
        away_team_score         as points_allowed,

        home_team_q1            as points_q1,
        home_team_q2            as points_q2,
        home_team_q3            as points_q3,
        home_team_q4            as points_q4,
        home_team_ot            as points_ot

    from games

),

away_side as (

    select
        game_key,
        game_id,
        game_date,
        season,
        week,
        season_type,
        is_postseason,
        went_to_overtime,

        away_team_key           as team_key,
        away_team_id            as team_id,
        home_team_key           as opponent_team_key,
        home_team_id            as opponent_team_id,
        false                   as is_home,

        away_team_score         as points_scored,
        home_team_score         as points_allowed,

        away_team_q1            as points_q1,
        away_team_q2            as points_q2,
        away_team_q3            as points_q3,
        away_team_q4            as points_q4,
        away_team_ot            as points_ot

    from games

),

team_games as (

    select * from home_side
    union all
    select * from away_side

),

box_score as (

    select * from {{ ref('stg_nfl__team_stats') }}

)

select
    -- ---------------------------------------------------------------
    -- keys
    -- ---------------------------------------------------------------
    {{ dbt_utils.generate_surrogate_key(['tg.game_id', 'tg.team_id']) }}   as team_game_key,
    tg.game_key,
    tg.game_id,
    tg.team_key,
    tg.team_id,
    tg.opponent_team_key,
    tg.opponent_team_id,
    {{ dbt_utils.generate_surrogate_key(['tg.game_date']) }}               as date_key,
    {{ dbt_utils.generate_surrogate_key(['tg.season', 'tg.week', 'tg.season_type']) }}
                                                                as season_week_key,

    -- ---------------------------------------------------------------
    -- degenerate dimensions / context
    -- ---------------------------------------------------------------
    tg.game_date,
    tg.season,
    tg.week,
    tg.season_type,
    tg.is_postseason,
    tg.is_home,
    tg.went_to_overtime,

    -- ---------------------------------------------------------------
    -- result. Ties are real in the NFL (rare, but they happen), so this is
    -- three flags rather than a single boolean.
    -- ---------------------------------------------------------------
    tg.points_scored,
    tg.points_allowed,
    tg.points_scored - tg.points_allowed                        as point_margin,
    (tg.points_scored > tg.points_allowed)                      as is_win,
    (tg.points_scored < tg.points_allowed)                      as is_loss,
    (tg.points_scored = tg.points_allowed)                      as is_tie,

    -- additive integer counters, so records aggregate with a plain sum
    iff(tg.points_scored > tg.points_allowed, 1, 0)             as win_count,
    iff(tg.points_scored < tg.points_allowed, 1, 0)             as loss_count,
    iff(tg.points_scored = tg.points_allowed, 1, 0)             as tie_count,

    -- scoring by period
    tg.points_q1,
    tg.points_q2,
    tg.points_q3,
    tg.points_q4,
    tg.points_ot,

    -- ---------------------------------------------------------------
    -- box score. NULL for the 4 team-game rows whose game has no team_stats.
    -- ---------------------------------------------------------------
    bs.first_downs,
    bs.first_downs_passing,
    bs.first_downs_rushing,
    bs.first_downs_penalty,

    bs.third_down_conversions,
    bs.third_down_attempts,
    bs.fourth_down_conversions,
    bs.fourth_down_attempts,
    bs.red_zone_scores,
    bs.red_zone_attempts,

    bs.total_drives,
    bs.total_offensive_plays,
    bs.possession_time_seconds,

    bs.total_yards,
    bs.yards_per_play,
    bs.net_passing_yards,
    bs.passing_completions,
    bs.passing_attempts,
    bs.yards_per_pass,
    bs.rushing_yards,
    bs.rushing_attempts,
    bs.yards_per_rush_attempt,

    bs.sacks_allowed,
    bs.sack_yards_lost,
    bs.turnovers,
    bs.fumbles_lost,
    bs.interceptions_thrown,
    bs.penalties,
    bs.penalty_yards,
    bs.defensive_touchdowns,

    -- flags whether the box score joined, so consumers can exclude the 4 gaps
    -- without needing to know which measure to null-check
    (bs.team_game_key is not null)                              as has_box_score

from team_games tg
left join box_score bs
    on  tg.game_id = bs.game_id
    and tg.team_id = bs.team_id
