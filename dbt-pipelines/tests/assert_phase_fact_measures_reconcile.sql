/*
    Every measure published by a phase fact must reconcile to the source total.

    This is the test that would have caught the fumble bug immediately. The
    defense fact published fumbles_recovered but omitted it from the activity
    filter, so 1,061 of 2,058 recoveries were unreachable -- row counts and
    uniqueness tests all passed, and takeaways was understated by 30% with
    nothing failing.

    The invariant: because the phase facts partition by ROW (never by column), a
    measure's sum in the fact must equal its sum in the source. Any measure that
    does not is being published by a fact whose filter cannot see it.

    Runs the check for one representative measure per phase per discipline,
    including all four fumble columns.
*/

with expected as (

    select 'passing_yards'      as measure, sum(passing_yards)      as src from {{ ref('stg_nfl__player_stats') }}
    union all select 'rushing_yards',        sum(rushing_yards)          from {{ ref('stg_nfl__player_stats') }}
    union all select 'receiving_yards',      sum(receiving_yards)        from {{ ref('stg_nfl__player_stats') }}
    union all select 'fumbles',              sum(fumbles)                from {{ ref('stg_nfl__player_stats') }}
    union all select 'fumbles_lost',         sum(fumbles_lost)           from {{ ref('stg_nfl__player_stats') }}
    union all select 'total_tackles',        sum(total_tackles)          from {{ ref('stg_nfl__player_stats') }}
    union all select 'defensive_sacks',      sum(defensive_sacks)        from {{ ref('stg_nfl__player_stats') }}
    union all select 'defensive_interceptions', sum(defensive_interceptions) from {{ ref('stg_nfl__player_stats') }}
    union all select 'fumbles_recovered',    sum(fumbles_recovered)      from {{ ref('stg_nfl__player_stats') }}
    union all select 'fumbles_touchdowns',   sum(fumbles_touchdowns)     from {{ ref('stg_nfl__player_stats') }}
    union all select 'field_goals_made',     sum(field_goals_made)       from {{ ref('stg_nfl__player_stats') }}
    union all select 'punts',                sum(punts)                  from {{ ref('stg_nfl__player_stats') }}
    union all select 'kick_return_yards',    sum(kick_return_yards)      from {{ ref('stg_nfl__player_stats') }}
    union all select 'punt_return_yards',    sum(punt_return_yards)      from {{ ref('stg_nfl__player_stats') }}

),

actual as (

    select 'passing_yards'      as measure, sum(passing_yards)      as fct from {{ ref('fact_player_game_offense') }}
    union all select 'rushing_yards',        sum(rushing_yards)          from {{ ref('fact_player_game_offense') }}
    union all select 'receiving_yards',      sum(receiving_yards)        from {{ ref('fact_player_game_offense') }}
    union all select 'fumbles',              sum(fumbles)                from {{ ref('fact_player_game_offense') }}
    union all select 'fumbles_lost',         sum(fumbles_lost)           from {{ ref('fact_player_game_offense') }}
    union all select 'total_tackles',        sum(total_tackles)          from {{ ref('fact_player_game_defense') }}
    union all select 'defensive_sacks',      sum(defensive_sacks)        from {{ ref('fact_player_game_defense') }}
    union all select 'defensive_interceptions', sum(defensive_interceptions) from {{ ref('fact_player_game_defense') }}
    union all select 'fumbles_recovered',    sum(fumbles_recovered)      from {{ ref('fact_player_game_defense') }}
    union all select 'fumbles_touchdowns',   sum(fumbles_touchdowns)     from {{ ref('fact_player_game_defense') }}
    union all select 'field_goals_made',     sum(field_goals_made)       from {{ ref('fact_player_game_special') }}
    union all select 'punts',                sum(punts)                  from {{ ref('fact_player_game_special') }}
    union all select 'kick_return_yards',    sum(kick_return_yards)      from {{ ref('fact_player_game_special') }}
    union all select 'punt_return_yards',    sum(punt_return_yards)      from {{ ref('fact_player_game_special') }}

)

select
    e.measure,
    e.src as source_total,
    a.fct as fact_total,
    e.src - a.fct as difference
from expected e
join actual a on e.measure = a.measure
-- equal_null so a measure that is entirely NULL on both sides passes rather
-- than producing a NULL comparison that silently drops the row
where not equal_null(e.src, a.fct)
