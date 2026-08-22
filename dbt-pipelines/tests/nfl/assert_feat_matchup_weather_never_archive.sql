/*
    Matchup weather is forecast preferred over hist_forecast. Archive / ERA5
    must never land on this table.
*/

select
    game_key,
    weather_product
from {{ ref('feat_game_matchup') }}
where weather_product = 'archive'
