{{ config(materialized='table') }}

/*
    fact_nextgen_passing -- NFL Next Gen Stats passing, weekly, from nflverse.
    Grain: player (gsis) x season x season_type x week.

    Week 0 (a season total that does not reconcile with the weekly sum) is
    excluded here and stays in the prep view, the same convention as the
    BallDontLie advanced facts. NO game_key: the source has no game id.
    Next Gen still tracks each player in one discipline only, so the
    cross-discipline caveat that keeps sv_nfl_player_advanced disabled
    applies to this vendor's tables too.
*/

select
    {{ dbt_utils.generate_surrogate_key(['n.gsis_id', 'n.season', 'n.season_type', 'n.week']) }}
                                                        as nextgen_passing_key,
    p.player_key,
    n.* exclude (is_season_total)
from {{ ref('stg_nfl__nflverse_nextgen_passing') }} n
left join {{ ref('bridge_player_ids') }} p
    on p.gsis_id = n.gsis_id
where not n.is_season_total
