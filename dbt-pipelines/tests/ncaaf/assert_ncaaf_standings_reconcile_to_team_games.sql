-- A team's CURRENT standings wins for a completed season should reconcile
-- to its counted wins in fact_ncaaf_team_game.
--
-- Scoped to COMPLETED seasons only (season < the max season with
-- scheduled games remaining): in-season, the standings snapshot and the
-- nightly game loads move at different cadences and disagree legitimately
-- for up to a week (the NFL standings backlog lesson, applied from day
-- one). Preseason NULL-wins rows are excluded by is_current + the season
-- scope together.
--
-- Tolerance of 1 win per team absorbs the known week-999 mislabel and any
-- game the standings compiler counts differently (conference title games);
-- systematic breakage moves every team, not one.

with completed_seasons as (

    select season
    from {{ ref('dim_ncaaf_game') }}
    group by season
    having count_if(not is_completed) = 0

),

standings as (

    select s.team_id, s.season, s.wins
    from {{ ref('fact_ncaaf_standing') }} s
    join completed_seasons cs on s.season = cs.season
    where s.is_current
      and s.wins is not null

),

counted as (

    select f.team_id, f.season, count_if(f.is_win) as counted_wins
    from {{ ref('fact_ncaaf_team_game') }} f
    join completed_seasons cs on f.season = cs.season
    group by f.team_id, f.season

)

select
    s.team_id,
    s.season,
    s.wins                                      as standings_wins,
    c.counted_wins,
    abs(s.wins - coalesce(c.counted_wins, 0))   as diff
from standings s
left join counted c
       on s.team_id = c.team_id
      and s.season = c.season
where abs(s.wins - coalesce(c.counted_wins, 0)) > 1
