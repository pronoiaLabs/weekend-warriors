-- games_to_date must count a player's games in calendar order within the
-- season type. The first version ordered the window by the fact's date_key, a
-- surrogate, which scrambled the count (week 1 read as game 13); this fails on
-- any row whose games_to_date disagrees with its rank by game date.

with offense as (

    select
        'app_player_weeks'                              as mart,
        player_key,
        season,
        season_type,
        game_key,
        game_date,
        games_to_date,
        row_number() over (
            partition by player_key, season, season_type order by game_date, game_key
        )                                               as by_date
    from {{ ref('app_player_weeks') }}

),

defense as (

    select
        'app_player_defense_weeks'                      as mart,
        player_key,
        season,
        season_type,
        game_key,
        game_date,
        games_to_date,
        row_number() over (
            partition by player_key, season, season_type order by game_date, game_key
        )                                               as by_date
    from {{ ref('app_player_defense_weeks') }}

)

select * from offense where games_to_date <> by_date
union all
select * from defense where games_to_date <> by_date
