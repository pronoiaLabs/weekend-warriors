{{ config(materialized='view') }}

/*
    1:1 forecast slice of fact_game_weather.

    Semantic views cannot filter a table. sv_nfl_schedule joins this view so
    the schedule grain stays one row per game. ERA5 / hist_forecast stay on
    fact_game_weather and off the schedule view.
*/

select * from {{ ref('fact_game_weather') }}
where product = 'forecast'
