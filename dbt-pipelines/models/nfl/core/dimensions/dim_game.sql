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

),

venues as (

    select
        venue_name,
        stadium_id
    from {{ ref('seed_nfl_stadiums') }}

)

select
    g.game_key,
    g.game_id,

    -- when. Both spellings of the same instant: UTC as loaded, and US
    -- Eastern for display. The schedule semantic view exposes only the ET one.
    g.game_datetime,
    g.game_datetime_et,
    g.game_date,
    {{ dbt_utils.generate_surrogate_key(['g.game_date']) }}                    as date_key,
    g.season,
    g.week,
    g.season_type,
    g.season_type_name,
    g.is_postseason,
    {{ dbt_utils.generate_surrogate_key(['g.season', 'g.week', 'g.season_type']) }} as season_week_key,

    -- where. venue is the feed string; stadium_key collapses aliases.
    g.venue,
    iff(
        v.stadium_id is not null,
        {{ dbt_utils.generate_surrogate_key(['v.stadium_id']) }},
        null
    )                                                                         as stadium_key,

    -- participants
    g.home_team_key,
    g.home_team_id,
    g.away_team_key,
    g.away_team_id,

    -- character of the game
    g.game_status,
    g.is_completed,
    g.went_to_overtime,
    g.game_summary

from games g
left join venues v
    on g.venue = v.venue_name
