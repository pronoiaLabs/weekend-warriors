-- app_team_situation's anchor rows must reproduce the fact exactly: the
-- 'overall' cut is a straight sum of fact_team_game_situation per
-- team-season-season_type-side, so any drift means a cut is dropping or
-- double-counting plays. Returns the rows that disagree.

with mart as (

    select
        team_key,
        season,
        season_type,
        side,
        plays
    from {{ ref('app_team_situation') }}
    where situation_group = 'overall'

),

fact as (

    select
        team_key,
        season,
        season_type,
        side,
        sum(plays) as plays
    from {{ ref('fact_team_game_situation') }}
    group by 1, 2, 3, 4

)

select
    coalesce(m.team_key, f.team_key)        as team_key,
    coalesce(m.season, f.season)            as season,
    coalesce(m.season_type, f.season_type)  as season_type,
    coalesce(m.side, f.side)                as side,
    m.plays                                 as mart_plays,
    f.plays                                 as fact_plays
from mart m
full outer join fact f
    on f.team_key = m.team_key
   and f.season = m.season
   and f.season_type = m.season_type
   and f.side = m.side
where coalesce(m.plays, -1) <> coalesce(f.plays, -1)
