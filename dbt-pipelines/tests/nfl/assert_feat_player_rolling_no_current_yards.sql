/*
    Player passing_yards_std must equal the sum of earlier RS/post passing
    yards for that player-season -- never the current game.
*/

with base as (

    select
        r.player_game_key,
        r.player_key,
        r.season,
        r.game_datetime,
        r.game_key,
        r.passing_yards_std,
        o.passing_yards
    from {{ ref('feat_player_game_rolling') }} r
    inner join {{ ref('fact_player_game_offense') }} o
        on r.player_game_key = o.player_game_key
    where r.is_completed
      and r.season_type in (2, 3)

),

expected as (

    select
        a.player_game_key,
        sum(b.passing_yards) as expected_passing_yards_std
    from base a
    left join base b
        on  a.player_key = b.player_key
        and a.season = b.season
        and (
            b.game_datetime < a.game_datetime
            or (b.game_datetime = a.game_datetime and b.game_key < a.game_key)
        )
    group by a.player_game_key

)

select
    a.player_game_key,
    a.passing_yards_std,
    e.expected_passing_yards_std
from base a
inner join expected e
    on a.player_game_key = e.player_game_key
where not equal_null(a.passing_yards_std, e.expected_passing_yards_std)
