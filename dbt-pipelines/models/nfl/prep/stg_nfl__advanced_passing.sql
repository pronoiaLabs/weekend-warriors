{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__advanced_passing -- Next Gen Stats passing.

    Grain: player x season x week x postseason. 1,783 rows.

    TWO TRAPS IN THIS SOURCE.

    1. week = 0 is the SEASON TOTAL, not a week. Those rows carry
       games_played = 17 and ~16,900 attempts against ~1,000 for a real week.
       Summing across all weeks would double-count the entire season.

       Worse, the totals do NOT reconcile with the weekly rows: 50,025 attempts
       at week 0 against 47,392 summed across weeks 1-18, with 83 of 138 players
       differing. So week 0 is independent authoritative data, not a derivable
       rollup -- it cannot be dropped and it cannot be recomputed.
       is_season_total flags it; the fact layer splits the two grains apart.

    2. There is no game_id. This source conforms to dim_player and
       dim_season_week but CANNOT be joined to a specific game. "What was his
       time to throw in Week 3" is answerable; "...against Dallas" is not.

    On conformance: dim_season_week is keyed on season_type (1/2/3), but this
    source only has a postseason boolean. That maps cleanly because the source
    never covers preseason -- postseason=false spans weeks 1-18 (the regular
    season) and true spans weeks 1-5 (the postseason). Verified, not assumed.

    The player payload dlt flattened in is dropped -- it lives on dim_player.
*/

with source as (

    select * from {{ source('nfl_raw', 'advanced_passing') }}

),

typed as (

    select
        *,
        -- see header: false = regular season, true = postseason, never preseason
        iff(postseason, 3, 2) as season_type
    from source

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season', 'week', 'postseason']) }}
                                                            as player_week_passing_key,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}          as player_key,
        player__id                                          as player_id,

        season,
        week,
        postseason                                          as is_postseason,
        season_type,

        -- week 0 rows are season totals, not weeks
        (week = 0)                                          as is_season_total,

        -- NULL for season-total rows, which belong to no single week
        case
            when week >= 1
            then {{ dbt_utils.generate_surrogate_key(['season', 'week', 'season_type']) }}
        end                                                 as season_week_key,

        games_played,

        -- volume
        attempts,
        completions,
        pass_yards,
        pass_touchdowns,
        interceptions,
        passer_rating,
        completion_percentage,

        -- Next Gen: expectation vs outcome. This is the reason this table exists
        -- -- completion percentage above expectation is a far better QB signal
        -- than raw completion percentage.
        expected_completion_percentage,
        completion_percentage_above_expectation,

        -- Next Gen: air yards and aggression
        aggressiveness,
        avg_air_distance,
        max_air_distance,
        avg_completed_air_yards,
        max_completed_air_distance,
        avg_intended_air_yards,
        avg_air_yards_differential,
        avg_air_yards_to_sticks,

        -- Next Gen: pocket time
        avg_time_to_throw

    from typed

)

select * from renamed
