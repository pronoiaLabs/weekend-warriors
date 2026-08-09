{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_team_game -- one row per team per game. Grain: team x game.

    478 rows = 239 games x 2 teams.

    This is the unpivot of stg_wnba__games (which stores home and away side by
    side) into the standard sports-star shape, with the team box score joined
    on. Every row answers "how did THIS team do in THIS game", carrying
    opponent_team_key so opponent analysis needs no self-join, and
    points_scored / points_allowed rather than home/away scores so that records
    and splits are plain aggregations.

    The unpivot is a UNION ALL of two selects over the same 239 rows, not a
    join, so it cannot fan out: exactly two rows per game by construction.
    tests/wnba/assert_wnba_fact_wnba_team_game_is_mirrored.sql guards that, plus
    the mirror property that one side's points_scored is the other's
    points_allowed.

    SCOPE IS GAMES WITH A RESULT, WHICH IS NOT THE SAME AS COMPLETED GAMES.
    The games source holds 333 rows: 93 still scheduled, and 240 marked
    complete. One of those 240, game 24935 on 2026-07-17, is a postponed game
    carrying STATUS 'post' with STATUS_STATE 'postponed' and a 0-0 line. Its
    scores survive the prep layer's null-out precisely because it is 'post',
    so is_completed alone would admit a fake scoreless draw with two zero
    scores, no winner, and two real team_stats rows behind it. The filter is
    therefore is_completed AND winner_team_id is not null, which drops it and
    leaves 239. Testing the score instead of the winner would not work: 0-0
    is what the row says. dim_wnba_game publishes the same rule as has_result.

    Dropping it takes two junk box scores with it, which is worth knowing:
    those two team_stats rows are the only ones in the whole table with a zero
    field goal percentage, and every one of their 17 measures is 0. Keeping
    the game would put two all-zero rows into every team average.

    TEAM POINTS COME FROM THE GAMES SCORES, NOT FROM THE BOX SCORE. The
    team_stats source has no points column at all -- it carries shooting,
    rebounding and playmaking but leaves scoring to the game record. So
    points_scored is home_team_score / away_team_score off the unpivot, and
    the box-score columns below are everything else. This is the one place the
    two sources meet, and it is why a player-points sum reconciles against a
    number that did not come from the same table (see
    tests/wnba/assert_wnba_player_box_reconciles_to_team_box.sql).

    Box score coverage: 474 of the 478 rows have one. The two 2026-08-08
    games, ids 24989 and 24990, have no team_stats rows -- the box-score load
    has not reached them. The join is a LEFT JOIN so those four team-game rows
    exist with the result populated and every box-score measure NULL, and
    has_box_score flags them without a consumer having to pick a column to
    null-check. Losing the games entirely would be worse than carrying the
    NULLs.

    NO TIE COLUMNS. Basketball does not have them: an equal score means the
    game did not produce a result and it has already been filtered out above,
    which is why is_win and is_loss are exhaustive here where the NFL fact
    needs a third flag.

    Season scope includes the All-Star game. season_type_name is on every row;
    filter on it rather than assuming regular season, and note that the
    All-Star row's teams are All-Star squads, not franchises.
*/

with games as (

    select * from {{ ref('stg_wnba__games') }}
    where is_completed
      and winner_team_id is not null

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
        season_type_name,
        is_postseason,
        went_to_overtime,

        home_team_key           as team_key,
        home_team_id            as team_id,
        away_team_key           as opponent_team_key,
        away_team_id            as opponent_team_id,
        true                    as is_home,

        home_team_score         as points_scored,
        away_team_score         as points_allowed

    from games

),

away_side as (

    select
        game_key,
        game_id,
        game_date,
        season,
        season_type_name,
        is_postseason,
        went_to_overtime,

        away_team_key           as team_key,
        away_team_id            as team_id,
        home_team_key           as opponent_team_key,
        home_team_id            as opponent_team_id,
        false                   as is_home,

        away_team_score         as points_scored,
        home_team_score         as points_allowed

    from games

),

team_games as (

    select * from home_side
    union all
    select * from away_side

),

box_score as (

    select * from {{ ref('stg_wnba__team_stats') }}

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

    -- ---------------------------------------------------------------
    -- degenerate dimensions / context
    -- ---------------------------------------------------------------
    tg.game_date,
    tg.season,
    tg.season_type_name,
    tg.is_postseason,
    tg.is_home,
    tg.went_to_overtime,

    -- ---------------------------------------------------------------
    -- result. Two flags, not three -- see header on ties.
    -- points come from the game record, not from box_score.
    -- ---------------------------------------------------------------
    tg.points_scored,
    tg.points_allowed,
    tg.points_scored - tg.points_allowed                        as point_margin,
    (tg.points_scored > tg.points_allowed)                      as is_win,
    (tg.points_scored < tg.points_allowed)                      as is_loss,

    -- additive integer counters, so records aggregate with a plain sum
    iff(tg.points_scored > tg.points_allowed, 1, 0)             as win_count,
    iff(tg.points_scored < tg.points_allowed, 1, 0)             as loss_count,

    -- ---------------------------------------------------------------
    -- box score. NULL for the 4 team-game rows whose game has no
    -- team_stats. Rates are on a 0-100 scale (46.2, not 0.462) and come
    -- straight from the source rather than being recomputed, so they are
    -- NOT additive: average them weighted by attempts, or recompute from
    -- the summed counts.
    -- ---------------------------------------------------------------
    bs.fgm                                                      as field_goals_made,
    bs.fga                                                      as field_goals_attempted,
    bs.fg_pct                                                   as field_goal_pct,
    bs.fg3m                                                     as three_pointers_made,
    bs.fg3a                                                     as three_pointers_attempted,
    bs.fg3_pct                                                  as three_point_pct,
    bs.ftm                                                      as free_throws_made,
    bs.fta                                                      as free_throws_attempted,
    bs.ft_pct                                                   as free_throw_pct,

    bs.oreb                                                     as offensive_rebounds,
    bs.dreb                                                     as defensive_rebounds,
    bs.reb                                                      as rebounds,

    bs.ast                                                      as assists,
    bs.stl                                                      as steals,
    bs.blk                                                      as blocks,
    bs.turnovers,
    bs.personal_fouls,

    -- flags whether the box score joined, so consumers can exclude the 4 gaps
    -- without needing to know which measure to null-check
    (bs.team_game_key is not null)                              as has_box_score

from team_games tg
left join box_score bs
    on  tg.game_id = bs.game_id
    and tg.team_id = bs.team_id
