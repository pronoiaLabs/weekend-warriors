/*
    fact_wnba_team_game must have exactly two rows per game -- one per team -- and
    the two rows must be mirror images: each team's points_scored is the
    other's points_allowed, and the two teams must be different.

    This is the test that would catch a broken unpivot. A UNION ALL cannot fan
    out, but a bad join condition or a mistaken home/away swap would show up
    here rather than as a row-count change.

    ONE EXTRA CHECK BEYOND THE NFL VERSION: exactly one winner per game.
    Basketball has no ties, and the fact filters out the games that have no
    result, so win_count summed over a game must be 1 and never 0 or 2. On the
    NFL side that assertion would be false -- a tie is a real outcome there --
    which is why the check lives here and not in the shared shape.

    Scope note: 239 games, not 240. The postponed game 24935 is complete with
    no score and is excluded from the fact, so it is absent from both sides of
    this test rather than failing it.
*/

with per_game as (

    select
        game_id,
        count(*)                          as n_rows,
        count(distinct team_id)           as n_teams,
        sum(points_scored)                as total_scored,
        sum(points_allowed)               as total_allowed,
        count_if(is_home)                 as n_home,
        count_if(not is_home)             as n_away,
        sum(win_count)                    as n_wins,
        sum(loss_count)                   as n_losses
    from {{ ref('fact_wnba_team_game') }}
    group by game_id

)

select
    game_id,
    n_rows,
    n_teams,
    total_scored,
    total_allowed,
    n_home,
    n_away,
    n_wins,
    n_losses
from per_game
where n_rows <> 2                        -- exactly two team rows
   or n_teams <> 2                       -- and two DISTINCT teams
   or n_home <> 1                        -- exactly one home side
   or n_away <> 1                        -- exactly one away side
   or total_scored <> total_allowed      -- points must mirror
   or n_wins <> 1                        -- exactly one winner, no ties
   or n_losses <> 1
