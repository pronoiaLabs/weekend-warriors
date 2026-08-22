/*
    The first regular-season game of a season must have an empty season-to-date
    window. If preseason occupied frame rows, n_games_played_std would be > 0.
*/

select
    team_key,
    season,
    game_id,
    n_games_played_std
from {{ ref('feat_team_game_rolling') }}
where is_completed
  and season_type = 2
qualify row_number() over (
    partition by team_key, season
    order by game_datetime, game_key
) = 1
  and n_games_played_std <> 0
