{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__team_stats -- team box score, one row per team per game.

    2,000 rows against an expected 2,004: two games have no team_stats row.
    fact_team_game left-joins this, so those four team-game rows carry a null
    box score rather than disappearing.

    dlt flattened the full game record and both teams into every row (73
    columns). Everything but game__id and team__id is dropped here -- those
    attributes belong on dim_game and dim_team.

    Two text columns are dropped in favour of their numeric siblings that the
    source already provides:
      third_down_efficiency  "5-12"  -> third_down_conversions / _attempts
      possession_time        "30:15" -> possession_time_seconds
*/

with source as (

    select * from {{ source('nfl_raw', 'team_stats') }}

),

renamed as (

    select
        -- grain: team x game
        {{ dbt_utils.generate_surrogate_key(['game__id', 'team__id']) }} as team_game_key,
        {{ dbt_utils.generate_surrogate_key(['game__id']) }}             as game_key,
        game__id                                                        as game_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}             as team_key,
        team__id                                                        as team_id,

        -- home_away comes off team_stats itself; fact_team_game derives its own
        -- is_home from games instead, since that covers all 2,004 rows
        home_away,

        -- drive / efficiency
        first_downs,
        first_downs_passing,
        first_downs_rushing,
        first_downs_penalty,
        third_down_conversions,
        third_down_attempts,
        fourth_down_conversions,
        fourth_down_attempts,
        red_zone_scores,
        red_zone_attempts,
        total_drives,
        total_offensive_plays,
        possession_time_seconds,

        -- yardage
        total_yards,
        yards_per_play,
        net_passing_yards,
        passing_completions,
        passing_attempts,
        yards_per_pass,
        rushing_yards,
        rushing_attempts,
        yards_per_rush_attempt,

        -- negative plays / turnovers
        sacks                                                           as sacks_allowed,
        sack_yards_lost,
        turnovers,
        fumbles_lost,
        interceptions_thrown,
        penalties,
        penalty_yards,

        -- defensive scoring credited to this team
        defensive_touchdowns

    from source

)

select * from renamed
