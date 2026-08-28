{{ config(materialized='table') }}

/*
    fact_nextgen_passing -- NFL Next Gen Stats passing, weekly, from nflverse.
    Grain: player (gsis) x season x season_type x week.

    Week 0 (a season total that does not reconcile with the weekly sum) is
    excluded here and stays in the prep view, the same convention as the
    season marts. Next Gen still tracks each player in one discipline only,
    so the cross-discipline caveat that retired sv_nfl_player_advanced
    applies to this vendor's tables too.

    The source has no game id, so game_key / player_game_key come from the
    week -> game resolution: season + week + the player's team against
    bridge_game_ids. Two vocabulary fixes, both measured: NGS writes LAR
    where nflverse play-by-play writes LA, and NGS numbers the Super Bowl
    week 23 where nflverse uses 22 (weeks 19-21 agree and NGS has no 22).
    Resolution lands 100% of rows, both season types (measured Aug 2026).
    player_game_key is the BDL phase facts' key (game_id x player_id), NULL
    where either bridge hop is missing, so a matched row joins the wide
    player facts directly. season_type is normalized to the numeric
    vocabulary the rest of the tree uses (2 regular, 3 postseason);
    nflverse_season_type keeps the source's REG/POST strings, and week stays
    NGS's own numbering.
*/

with ngs as (

    select * from {{ ref('stg_nfl__nflverse_nextgen_passing') }}
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
                                                        as nextgen_passing_key,
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
