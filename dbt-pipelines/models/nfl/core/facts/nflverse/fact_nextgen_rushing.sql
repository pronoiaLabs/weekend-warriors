{{ config(materialized='table') }}

/*
    fact_nextgen_rushing -- NFL Next Gen Stats rushing, weekly, from nflverse.
    Grain: player (gsis) x season x season_type x week. Same conventions as
    fact_nextgen_passing: week-0 season totals excluded, no game_key,
    one-discipline-per-player caveat.
*/

select
    {{ dbt_utils.generate_surrogate_key(['n.gsis_id', 'n.season', 'n.season_type', 'n.week']) }}
                                                        as nextgen_rushing_key,
    p.player_key,
    n.* exclude (is_season_total)
from {{ ref('stg_nfl__nflverse_nextgen_rushing') }} n
left join {{ ref('bridge_player_ids') }} p
    on p.gsis_id = n.gsis_id
where not n.is_season_total
