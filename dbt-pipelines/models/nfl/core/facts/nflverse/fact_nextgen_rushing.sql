{{ config(materialized='table') }}

/*
    fact_nextgen_rushing -- NFL Next Gen Stats rushing, weekly, from nflverse.
    Grain: player (gsis) x season x season_type x week. Same conventions as
    fact_nextgen_passing: week-0 season totals excluded, one-discipline-per-
    player caveat, game_key / player_game_key via the week -> game resolution
    (LAR -> LA, NGS Super Bowl week 23 -> nflverse 22), numeric season_type
    with nflverse_season_type keeping the source's REG/POST strings.
*/

with ngs as (

    select * from {{ ref('stg_nfl__nflverse_nextgen_rushing') }}
    where not is_season_total

),

players as (

    select gsis_id, player_key, player_id from {{ ref('bridge_player_ids') }}

),

games as (

    select game_key, game_id, season, nflverse_week,
           home_abbr_nflverse, away_abbr_nflverse
    from {{ ref('bridge_game_ids') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['n.gsis_id', 'n.season', 'n.season_type', 'n.week']) }}
                                                        as nextgen_rushing_key,
    p.player_key,
    g.game_key,
    g.game_id,
    case
        when g.game_id is not null and p.player_id is not null
        then {{ dbt_utils.generate_surrogate_key(['g.game_id', 'p.player_id']) }}
    end                                                 as player_game_key,
    iff(n.season_type = 'POST', 3, 2)                   as season_type,
    n.season_type                                       as nflverse_season_type,
    n.* exclude (is_season_total, season_type)
from ngs n
left join players p
    on p.gsis_id = n.gsis_id
left join games g
    on  g.season = n.season
    and g.nflverse_week = iff(n.season_type = 'POST' and n.week = 23, 22, n.week)
    and iff(n.team_abbr = 'LAR', 'LA', n.team_abbr)
            in (g.home_abbr_nflverse, g.away_abbr_nflverse)
