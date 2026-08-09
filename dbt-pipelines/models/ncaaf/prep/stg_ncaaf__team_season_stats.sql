{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__team_season_stats -- one row per team per season, ~270 rows.

    FBS COVERAGE ONLY: about 135 FBS programs x 2 completed seasons. FCS
    teams have game-grain stats but no season rollup here, so anything
    promising season-level team metrics must scope itself to FBS (the
    semantic view's AI rules say so).

    Kept because it carries what the game grain cannot cheaply reproduce:
    the per-game rate columns and the opponent totals (OPP_PASSING_YARDS,
    OPP_RUSHING_YARDS), which exist nowhere else in the source.

    VARIANT TWIN folded here: PASSING_YARDS_PER_GAME.
*/

with source as (

    select * from {{ source('ncaaf_raw', 'team_season_stats') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season']) }}
                                                            as team_season_key,

        {{ dbt_utils.generate_surrogate_key(['team__id']) }}   as team_key,
        team__id                                            as team_id,
        season,

        passing_yards,
        {{ ncaaf_coalesce_variant('passing_yards_per_game') }}
                                                            as passing_yards_per_game,
        passing_touchdowns,
        passing_interceptions,
        passing_qb_rating,

        rushing_yards,
        rushing_yards_per_game,
        rushing_touchdowns,

        receiving_yards,
        receiving_touchdowns,

        opp_passing_yards,
        opp_rushing_yards

    from source

)

select * from renamed
