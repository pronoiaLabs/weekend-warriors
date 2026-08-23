{{ config(materialized='table') }}

/*
    fact_player_week_snaps -- participation, one row per player per game.
    Grain: pfr_player x game (pfr_game_id, pfr_player_id).

    Snap counts key on Pro Football Reference ids; the path to everything
    else runs pfr_id -> gsis_id (stg_nfl__nflverse_players) -> player_key
    (bridge_player_ids), NULL where a hop is missing. Snap share is the
    usage signal the box score hides: a 30%-snap back and a 90%-snap back
    with the same carries are different bets.
*/

with snaps as (

    select * from {{ ref('stg_nfl__nflverse_snap_counts') }}

),

crosswalk as (

    select pfr_id, gsis_id
    from {{ ref('stg_nfl__nflverse_players') }}
    where pfr_id is not null

),

players as (

    select gsis_id, player_key from {{ ref('bridge_player_ids') }}

),

games as (

    select
        nflverse_game_id,
        game_key,
        game_id,
        home_abbr_nflverse,
        home_team_key,
        away_abbr_nflverse,
        away_team_key
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['s.pfr_game_id', 's.pfr_player_id']) }}
                                                        as player_game_snap_key,
    x.gsis_id,
    p.player_key,
    g.game_key,
    g.game_id,
    case s.team
        when g.home_abbr_nflverse then g.home_team_key
        when g.away_abbr_nflverse then g.away_team_key
    end                                                 as team_key,
    s.nflverse_game_id,
    s.pfr_game_id,
    s.pfr_player_id,
    s.player_name,
    s.position,
    s.team,
    s.opponent,
    s.season,
    s.game_type,
    s.week,
    s.offense_snaps,
    s.offense_pct,
    s.defense_snaps,
    s.defense_pct,
    s.st_snaps,
    s.st_pct,
    s.loaded_at
from snaps s
left join crosswalk x
    on x.pfr_id = s.pfr_player_id
left join players p
    on p.gsis_id = x.gsis_id
left join games g
    on g.nflverse_game_id = s.nflverse_game_id
