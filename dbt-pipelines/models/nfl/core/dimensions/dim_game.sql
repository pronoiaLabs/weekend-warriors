{{
    config(
        materialized='table'
    )
}}

/*
    dim_game -- descriptive context for each game. Grain: game.

    THE ONLY PLACE THE FULL NFL SLATE IS READABLE. fact_team_game filters to
    completed games (an unplayed game has no fact rows), so scheduled games
    exist solely here, flagged by is_completed. The schedule semantic view
    anchors on this table for exactly that reason.

    Scores live on fact_team_game, not here. dim_game answers "when, where, who
    played, what kind of game was it"; the outcome is a measure and belongs in
    the fact. went_to_overtime is the exception -- it is a characteristic of the
    game rather than a quantity, so it sits here as a dimension attribute.

    home_team_key and away_team_key are kept as a convenience for questions
    phrased in home/away terms. fact_team_game additionally exposes
    opponent_team_key, which is the easier path for most analysis.
*/

with games as (

    select * from {{ ref('stg_nfl__games') }}

)

select
    game_key,
    game_id,

    -- when. Both spellings of the same instant: UTC as loaded, and US
    -- Eastern for display. The schedule semantic view exposes only the ET one.
    game_datetime,
    game_datetime_et,
    game_date,
    {{ dbt_utils.generate_surrogate_key(['game_date']) }}                     as date_key,
    season,
    week,
    season_type,
    season_type_name,
    is_postseason,
    {{ dbt_utils.generate_surrogate_key(['season', 'week', 'season_type']) }}  as season_week_key,

    -- where
    venue,

    -- participants
    home_team_key,
    home_team_id,
    away_team_key,
    away_team_id,

    -- character of the game
    game_status,
    is_completed,
    went_to_overtime,
    game_summary

from games
