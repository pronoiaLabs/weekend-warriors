/*
    fact_team_game_offense must have exactly two rows per game -- one per team -- and the
    two rows must be mirror images: each team's points_scored is the other's
    points_allowed, and the two teams must be different.

    This is the test that would catch a broken unpivot. A UNION ALL cannot fan
    out, but a bad join condition or a mistaken home/away swap would show up
    here rather than as a row-count change.
*/

with per_game as (

    select
        game_id,
        count(*)                          as n_rows,
        count(distinct team_id)            as n_teams,
        sum(points_scored)                as total_scored,
        sum(points_allowed)               as total_allowed,
        count_if(is_home)                 as n_home,
        count_if(not is_home)             as n_away
    from {{ ref('fact_team_game_offense') }}
    group by game_id

)

select
    game_id,
    n_rows,
    n_teams,
    total_scored,
    total_allowed,
    n_home,
    n_away
from per_game
where n_rows <> 2                        -- exactly two team rows
   or n_teams <> 2                       -- and two DISTINCT teams
   or n_home <> 1                        -- exactly one home side
   or n_away <> 1                        -- exactly one away side
   or total_scored <> total_allowed      -- points must mirror
