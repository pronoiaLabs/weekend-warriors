/*
    Leaderboard totals equal the fact. For every player-season-season type,
    app_player_leaders' fantasy points, scrimmage yards and games must match
    what fact_player_game_offense sums to; a dropped or duplicated player-game
    anywhere in the app chain shows up here.
*/

with fact_side as (

    select
        player_key,
        season,
        season_type,
        count(*)                                        as games,
        sum(fanduel_points)                             as fanduel_points,
        sum(draftkings_points)                          as draftkings_points,
        sum(scrimmage_yards)                            as scrimmage_yards
    from {{ ref('fact_player_game_offense') }}
    group by 1, 2, 3

),

app_side as (

    select
        player_key, season, season_type, games, fanduel_points, draftkings_points, scrimmage_yards
    from {{ ref('app_player_leaders') }}

)

select
    f.player_key,
    f.season,
    f.season_type,
    f.games                                             as fact_games,
    a.games                                             as app_games,
    f.fanduel_points                                    as fact_fanduel,
    a.fanduel_points                                    as app_fanduel
from fact_side f
full outer join app_side a
    on a.player_key = f.player_key
   and a.season = f.season
   and a.season_type = f.season_type
where a.player_key is null
   or f.player_key is null
   or f.games <> a.games
   or abs(coalesce(f.fanduel_points, 0) - coalesce(a.fanduel_points, 0)) > 0.01
   or abs(coalesce(f.draftkings_points, 0) - coalesce(a.draftkings_points, 0)) > 0.01
   or coalesce(f.scrimmage_yards, 0) <> coalesce(a.scrimmage_yards, 0)
