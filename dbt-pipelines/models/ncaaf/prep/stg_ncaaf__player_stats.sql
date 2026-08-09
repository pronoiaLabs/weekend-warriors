{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__player_stats -- one row per player per completed game,
    ~173,688 rows (2024-2025; 2026 accrues as games are played).

    The source embeds the FULL game payload on every row (GAME__* including
    all score columns) but NOT the game's team blocks, so home/away identity
    is NOT knowable from this table alone; it joins from stg_ncaaf__games.
    Per house style the repeated parent payload is stripped and only the
    join keys plus the season/week/date context worth carrying survive.

    COVERAGE: 22 stat fields across passing, rushing, receiving and defense.
    No fumbles, no kicking or punting, no returns -- the API does not carry
    them for college, so a downstream view must not promise special teams.

    VARIANT TWINS folded here (see the ncaaf_raw registry):
    TACKLES_FOR_LOSS, PASSING_QBR, SACKS.
*/

with source as (

    select * from {{ source('ncaaf_raw', 'player_stats') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['player__id', 'game__id']) }}
                                                            as player_game_key,

        {{ dbt_utils.generate_surrogate_key(['player__id']) }} as player_key,
        player__id                                          as player_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}   as team_key,
        team__id                                            as team_id,
        {{ dbt_utils.generate_surrogate_key(['game__id']) }}   as game_key,
        game__id                                            as game_id,

        -- game context worth carrying; everything else joins from games
        game__season                                        as season,
        game__week                                          as week,
        game__date::date                                    as game_date,

        -- passing
        passing_completions,
        passing_attempts,
        passing_yards,
        passing_touchdowns,
        passing_interceptions,
        {{ ncaaf_coalesce_variant('passing_qbr') }}         as passing_qbr,
        passing_rating,

        -- rushing
        rushing_attempts,
        rushing_yards,
        rushing_touchdowns,
        rushing_long,

        -- receiving. No targets: the API documents receiving_targets but has
        -- never returned a non-null value, and dlt drops all-null columns,
        -- so the column does not exist in RAW.
        receptions,
        receiving_yards,
        receiving_touchdowns,
        receiving_long,

        -- defense
        total_tackles,
        solo_tackles,
        {{ ncaaf_coalesce_variant('tackles_for_loss') }}    as tackles_for_loss,
        {{ ncaaf_coalesce_variant('sacks') }}               as sacks,
        interceptions,
        passes_defended

    from source

)

select * from renamed
