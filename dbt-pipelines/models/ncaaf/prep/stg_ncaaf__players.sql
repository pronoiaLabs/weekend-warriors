{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__players -- one row per player, 124,089 rows: the largest
    reference table in the account (FBS + FCS rosters, with churn kept by the
    weekly merge).

    CARRIES A CURRENT TEAM only, like the WNBA dimension: the source has no
    season-team history, and fact_ncaaf_player_game.team_key is the
    season-accurate answer wherever the grain allows.

    HEIGHT, WEIGHT and JERSEY_NUMBER are TEXT in the source and arrived in a
    later schema evolution, so early-loaded rows hold NULL. Weight and jersey
    cast cleanly to integers; height is a display string (e.g. 6'2") and is
    passed through as text rather than parsed into a number nobody has asked
    for yet.
*/

with source as (

    select * from {{ source('ncaaf_raw', 'players') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['id']) }}       as player_key,
        id                                                   as player_id,
        first_name,
        last_name,

        -- 9 roster stubs have both name parts NULL upstream. They stay (a
        -- stat row could reference the id) with an explicit unknown member,
        -- so full_name keeps its not_null guarantee without inventing names.
        coalesce(
            nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''),
            'Unknown player #' || id
        )                                                    as full_name,

        position                                             as position_name,
        position_abbreviation,

        height                                               as height_text,
        try_cast(weight as int)                              as weight_lbs,
        try_cast(jersey_number as int)                       as jersey_number,

        -- current team, not a historical one
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as current_team_key,
        team__id                                             as current_team_id,
        team__college                                        as current_team_college,
        team__abbreviation                                   as current_team_abbreviation

    from source

)

select * from renamed
