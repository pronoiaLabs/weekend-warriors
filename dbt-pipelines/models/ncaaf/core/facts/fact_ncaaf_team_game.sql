{{
    config(
        materialized='table'
    )
}}

/*
    fact_ncaaf_team_game -- one row per team per COMPLETED game: the
    unpivoted result grain, two rows per game (~6,708 today).

    COMPLETED GAMES ONLY, by construction (where is_completed): scheduled
    games have no fact rows anywhere; the slate lives on dim_ncaaf_game.

    ANCHORED ON GAMES, NOT ON TEAM_STATS: a handful of completed games have
    no team_stats rows upstream, and a game that was played must not vanish
    from results because its box score is missing. Scores and results come
    from the games unpivot; the yardage block LEFT JOINs in and is NULL for
    those games (NULL, not zero: zero yards is a claim).

    result is 'W' / 'L' / 'T': ties were possible historically, so the tie
    member exists even though modern overtime rules make it rare-to-never.
*/

with games as (

    select * from {{ ref('stg_ncaaf__games') }}
    where is_completed  -- scheduled games have no fact rows, see header

),

sides as (

    -- home side
    select
        {{ dbt_utils.generate_surrogate_key(['game_id', 'home_team_id']) }}
                                                as team_game_key,
        game_key,
        game_id,
        game_date,
        season,
        week,
        is_postseason,
        went_to_overtime,
        home_team_key                           as team_key,
        home_team_id                            as team_id,
        away_team_key                           as opponent_team_key,
        away_team_id                            as opponent_team_id,
        true                                    as is_home,
        home_team_score                         as points_scored,
        away_team_score                         as points_allowed
    from games

    union all

    -- away side
    select
        {{ dbt_utils.generate_surrogate_key(['game_id', 'away_team_id']) }},
        game_key,
        game_id,
        game_date,
        season,
        week,
        is_postseason,
        went_to_overtime,
        away_team_key,
        away_team_id,
        home_team_key,
        home_team_id,
        false,
        away_team_score,
        home_team_score
    from games

)

select
    s.team_game_key,
    s.game_key,
    s.game_id,
    s.game_date,
    s.season,
    s.week,
    s.is_postseason,
    s.went_to_overtime,
    s.team_key,
    s.team_id,
    s.opponent_team_key,
    s.opponent_team_id,
    s.is_home,
    s.points_scored,
    s.points_allowed,
    s.points_scored - s.points_allowed          as point_differential,

    case
        when s.points_scored > s.points_allowed then 'W'
        when s.points_scored < s.points_allowed then 'L'
        else 'T'
    end                                         as result,
    (s.points_scored > s.points_allowed)        as is_win,

    -- box-score block: NULL when the upstream stat row is missing
    t.first_downs,
    t.third_down_conversions,
    t.third_down_attempts,
    t.fourth_down_conversions,
    t.fourth_down_attempts,
    t.passing_yards,
    t.rushing_yards,
    t.total_yards,
    t.turnovers,
    t.penalties,
    t.penalty_yards,
    t.possession_minutes,
    (t.team_game_key is not null)               as has_box_score

from sides s
left join {{ ref('stg_ncaaf__team_stats') }} t
       on s.game_id = t.game_id
      and s.team_id = t.team_id
