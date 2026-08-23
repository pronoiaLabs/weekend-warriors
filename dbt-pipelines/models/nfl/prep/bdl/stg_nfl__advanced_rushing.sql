{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__advanced_rushing -- Next Gen Stats rushing.

    Grain: player x season x week x postseason. 1,813 rows.

    Same two traps as stg_nfl__advanced_passing -- read that header first:
      * week = 0 is the SEASON TOTAL, not a week, and does not reconcile with
        the sum of the weekly rows. is_season_total flags it.
      * no game_id, so this cannot be tied to a specific game.
*/

with source as (

    select * from {{ source('nfl_raw', 'advanced_rushing') }}

),

typed as (

    select
        *,
        iff(postseason, 3, 2) as season_type
    from source

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season', 'week', 'postseason']) }}
                                                            as player_week_rushing_key,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}          as player_key,
        player__id                                          as player_id,

        season,
        week,
        postseason                                          as is_postseason,
        season_type,
        (week = 0)                                          as is_season_total,
        case
            when week >= 1
            then {{ dbt_utils.generate_surrogate_key(['season', 'week', 'season_type']) }}
        end                                                 as season_week_key,

        -- volume
        rush_attempts,
        rush_yards,
        rush_touchdowns,
        avg_rush_yards,

        -- Next Gen: expectation vs outcome. Rush yards over expected isolates
        -- the runner's contribution from the blocking in front of him.
        expected_rush_yards,
        rush_yards_over_expected,
        rush_yards_over_expected_per_att,
        rush_pct_over_expected,

        -- Next Gen: how the defence played him, and how fast he hit the hole
        efficiency,
        percent_attempts_gte_eight_defenders,
        avg_time_to_los

    from typed

)

select * from renamed
