{{ config(materialized='table') }}

/*
    fact_injury_report -- the league's official injury report, game-anchored.
    Grain: season x season_type x week x team x player (gsis).

    The filing every club must make: report_status is the game designation
    (Out, Doubtful, Questionable), practice_status the participation line.
    game_key is the team's game that week through bridge_game_ids, NULL when
    the week has no bridged game for the team (early historical gaps).
    modified_before_kickoff is the leakage guard for FEATURES: only rows
    already true at kickoff existed then.
*/

with injuries as (

    select * from {{ ref('stg_nfl__nflverse_injuries') }}

),

games as (

    select
        game_key,
        game_id,
        season,
        nflverse_week,
        game_datetime,
        home_abbr_nflverse,
        home_team_key,
        away_abbr_nflverse,
        away_team_key
    from {{ ref('bridge_game_ids') }}
    where nflverse_game_id is not null

),

players as (

    select gsis_id, player_key from {{ ref('bridge_player_ids') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['i.season', 'i.season_type', 'i.week', 'i.team', 'i.gsis_id']) }}
                                                        as injury_report_key,
    p.player_key,
    i.gsis_id,
    g.game_key,
    g.game_id,
    case i.team
        when g.home_abbr_nflverse then g.home_team_key
        when g.away_abbr_nflverse then g.away_team_key
    end                                                 as team_key,
    i.season,
    i.season_type,
    i.game_type,
    i.week,
    i.team                                              as team_abbr_nflverse,
    i.position,
    i.full_name,
    i.report_status,
    i.report_primary_injury,
    i.report_secondary_injury,
    i.practice_status,
    i.practice_primary_injury,
    i.practice_secondary_injury,
    to_timestamp_tz(i.date_modified::string)            as modified_at,
    iff(
        g.game_datetime is null,
        null,
        to_timestamp_tz(i.date_modified::string) < g.game_datetime
    )                                                   as modified_before_kickoff,
    i.loaded_at
from injuries i
left join games g
    on  g.season = i.season
    and g.nflverse_week = i.week
    and i.team in (g.home_abbr_nflverse, g.away_abbr_nflverse)
left join players p
    on p.gsis_id = i.gsis_id
