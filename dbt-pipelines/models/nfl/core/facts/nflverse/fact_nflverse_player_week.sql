{{ config(materialized='table') }}

/*
    fact_nflverse_player_week -- nflverse's player week, conformed.
    Grain: player (gsis) x season x season_type x week.

    The usage and efficiency measures BallDontLie cannot give: target_share,
    air_yards_share, wopr, racr, EPA by phase, CPOE, both fantasy scorings.
    A bye week has no row by construction. Deliberately NOT reconciled
    row-for-row with fact_player_game_offense: this is week grain from a
    different provider, joined to the same games through bridge_game_ids and
    to the same players through bridge_player_ids; player_key and game_key
    are NULL where a bridge has no row (an unbridged player, a game outside
    BallDontLie's coverage).
*/

with stats as (

    select * from {{ ref('stg_nfl__nflverse_player_stats') }}

),

players as (

    select gsis_id, player_key from {{ ref('bridge_player_ids') }}

),

games as (

    select nflverse_game_id, game_key, game_id
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['s.gsis_id', 's.season', 's.season_type', 's.week']) }}
                                                        as player_week_key,
    p.player_key,
    g.game_key,
    g.game_id,
    {{ dbt_utils.generate_surrogate_key(['s.season', 's.week', "iff(s.season_type = 'POST', 3, 2)"]) }}
                                                        as season_week_key,
    s.* exclude (loaded_at),
    s.loaded_at
from stats s
left join players p
    on p.gsis_id = s.gsis_id
left join games g
    on g.nflverse_game_id = s.nflverse_game_id
