{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__advanced_receiving -- Next Gen Stats receiving.

    Grain: player x season x week x postseason. 4,189 rows -- the largest of the
    three Next Gen tables, since far more players catch passes than throw or
    carry them.

    Same two traps as stg_nfl__advanced_passing -- read that header first:
      * week = 0 is the SEASON TOTAL, not a week, and does not reconcile with
        the sum of the weekly rows. is_season_total flags it.
      * no game_id, so this cannot be tied to a specific game.

    catch_percentage is one of the dlt variant-split fields: the source has both
    catch_percentage (NUMBER, 1,751 rows) and catch_percentage__v_double (FLOAT,
    2,438 rows). Verified mutually exclusive, so the coalesce is lossless.
*/

with source as (

    select * from {{ source('nfl_raw', 'advanced_receiving') }}

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
                                                            as player_week_receiving_key,
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
        targets,
        receptions,
        yards,
        rec_touchdowns,
        coalesce(catch_percentage::float, catch_percentage__v_double)
                                                            as catch_percentage,

        -- Next Gen: separation and coverage. avg_cushion is how far off the
        -- defender lined up; avg_separation is the gap at the catch point.
        avg_cushion,
        avg_separation,

        -- Next Gen: yards after catch vs expectation
        avg_yac,
        avg_expected_yac,
        avg_yac_above_expectation,

        -- Next Gen: role in the offence
        avg_intended_air_yards,
        percent_share_of_intended_air_yards

    from typed

)

select * from renamed
