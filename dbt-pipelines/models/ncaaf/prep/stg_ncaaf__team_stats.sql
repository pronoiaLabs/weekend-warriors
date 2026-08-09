{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__team_stats -- one row per team per completed game, ~6,698 rows.

    A handful of completed games have no rows here, which is why
    fact_ncaaf_team_game anchors on games and LEFT JOINs this table rather
    than the reverse.

    The source's GAME__* block is the trimmed 4-field stub (id, date, season,
    week), unlike player_stats which embeds the whole game.

    TEXT PARSING: THIRD/FOURTH_DOWN_EFFICIENCY arrive as '5-12'
    made-attempts strings and POSSESSION_TIME as '31:24'. All three are
    parsed here into numerics (and the raw strings dropped: the parsed pairs
    reproduce them exactly, and two spellings of the same fact downstream is
    an invitation to use the wrong one).
*/

with source as (

    select * from {{ source('ncaaf_raw', 'team_stats') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['team__id', 'game__id']) }}
                                                            as team_game_key,

        {{ dbt_utils.generate_surrogate_key(['team__id']) }}   as team_key,
        team__id                                            as team_id,
        {{ dbt_utils.generate_surrogate_key(['game__id']) }}   as game_key,
        game__id                                            as game_id,
        game__season                                        as season,
        game__week                                          as week,
        game__date::date                                    as game_date,

        first_downs,
        {{ ncaaf_parse_efficiency('third_down_efficiency', 'made') }}
                                                            as third_down_conversions,
        {{ ncaaf_parse_efficiency('third_down_efficiency', 'attempts') }}
                                                            as third_down_attempts,
        {{ ncaaf_parse_efficiency('fourth_down_efficiency', 'made') }}
                                                            as fourth_down_conversions,
        {{ ncaaf_parse_efficiency('fourth_down_efficiency', 'attempts') }}
                                                            as fourth_down_attempts,

        passing_yards,
        rushing_yards,
        total_yards,
        turnovers,
        penalties,
        penalty_yards,
        {{ ncaaf_parse_clock_minutes('possession_time') }}  as possession_minutes

    from source

)

select * from renamed
