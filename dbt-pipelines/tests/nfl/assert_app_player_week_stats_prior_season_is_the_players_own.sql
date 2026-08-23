/*
    The year-over-year columns compare a player to himself: prior_season_same_week
    must equal the value on the same player's row one season earlier, same week
    and season type, wherever that row exists, and be NULL where it does not.
*/

with stats as (

    select * from {{ ref('app_player_week_stats') }}

)

select
    cur.player_key,
    cur.season,
    cur.week,
    cur.stat_key,
    cur.prior_season_same_week,
    prev.value                                          as expected
from stats cur
left join stats prev
    on prev.player_key = cur.player_key
   and prev.season = cur.season - 1
   and prev.season_type = cur.season_type
   and prev.week = cur.week
   and prev.stat_key = cur.stat_key
where coalesce(cur.prior_season_same_week, -1) <> coalesce(prev.value, -1)
