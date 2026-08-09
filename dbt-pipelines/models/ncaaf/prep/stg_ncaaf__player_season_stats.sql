{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__player_season_stats -- one row per player per season,
    ~17,198 rows (2024-2025).

    THE SOURCE CARRIES TWO TEAM BLOCKS: a top-level TEAM__* (the team the
    stat line was earned for) and a nested PLAYER__TEAM__* (the player's
    CURRENT team, repeated from the players payload). They disagree across
    transfers, and this model deliberately keeps only the stat-line TEAM__*:
    season stats belong to the team they were earned for.

    VARIANT TWIN folded here: RECEIVING_YARDS_PER_GAME -- the most dangerous
    twin in the schema, because the base column is NUMBER and a per-game
    average is almost always fractional, so reading the base column alone
    discards nearly every real value.
*/

with source as (

    select * from {{ source('ncaaf_raw', 'player_season_stats') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season']) }}
                                                            as player_season_key,

        {{ dbt_utils.generate_surrogate_key(['player__id']) }} as player_key,
        player__id                                          as player_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}   as team_key,
        team__id                                            as team_id,
        season,

        -- passing
        passing_completions,
        passing_attempts,
        passing_yards,
        passing_yards_per_game,
        passing_touchdowns,
        passing_interceptions,
        passing_rating,

        -- rushing
        rushing_attempts,
        rushing_yards,
        rushing_yards_per_game,
        rushing_avg,
        rushing_touchdowns,

        -- receiving
        receptions,
        receiving_yards,
        {{ ncaaf_coalesce_variant('receiving_yards_per_game') }}
                                                            as receiving_yards_per_game,
        receiving_avg,
        receiving_touchdowns,

        -- defense. No tackles_for_loss at season grain: the API has never
        -- returned it here and dlt drops all-null columns (the game grain
        -- has it).
        total_tackles,
        solo_tackles,
        sacks,
        interceptions,
        passes_defended

    from source

)

select * from renamed
