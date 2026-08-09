-- Every published poll week must look like a Top 25: 25 rows (26 allowed
-- for a rank tie, which 2024 actually produced), ranks inside 1-25, and no
-- team appearing twice in one week.
--
-- If the provider ever adds a second poll to the same unnamed endpoint,
-- the row count doubles and this fails -- which is the alarm we want,
-- because the rows would otherwise collide invisibly (no poll id exists).

with weeks as (

    select
        season,
        week,
        count(*)                                as rows_in_week,
        count(distinct team_id)                 as distinct_teams,
        min(poll_rank)                          as min_rank,
        max(poll_rank)                          as max_rank
    from {{ ref('fact_ncaaf_ranking') }}
    group by season, week

)

select *
from weeks
where rows_in_week not between 25 and 26
   or distinct_teams <> rows_in_week
   or min_rank <> 1
   or max_rank > 25
