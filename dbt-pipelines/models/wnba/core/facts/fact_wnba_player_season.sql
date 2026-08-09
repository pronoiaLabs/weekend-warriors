{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_player_season -- basic season line. Grain: player x season x season
    type. 196 rows, all 2026 regular season today.

    EVERY MEASURE HERE IS A PER-GAME AVERAGE, NOT A SEASON TOTAL, and every
    column is named to say so. points_per_game of 26.62 is 26.62 points a game
    across 29 games; SUM(points_per_game) over players is a number with no
    meaning. The names are deliberately not the source's terse pts / reb / ast,
    precisely so that nobody sums them by reflex. Multiply by games_played for
    a total, having first read the caveat on games_played below.

    NOT A ROLLUP OF fact_wnba_player_game. It is a separate endpoint, and the two
    disagree for about a third of players: the source's own games_played does
    not match the number of games the box scores show the player playing. Where
    they do agree, the averages agree to within 0.005, which is the rounding
    half-step of a two-decimal source.
    tests/wnba/assert_wnba_player_season_reconciles_to_player_games.sql
    measures both halves and is the place to look before treating a difference
    as a bug. Where a true season total is needed and this fact cannot supply
    it, fact_wnba_player_game is the authoritative path.

    games_played IS THE SOURCE'S AND IT IS SOMETIMES WRONG. 18 of 196 rows
    report more games than the leading team has played all season -- player 384
    reads 38 and player 495 reads 44, against a league maximum of 33. It is
    carried anyway because it is the denominator the source itself used to
    compute every average on the row, so replacing it with a corrected count
    would leave the denominator disagreeing with the numerators. Treat it as
    metadata about the average, not as a count of appearances; for that,
    count non-DNP rows in fact_wnba_player_game.

    SUBSET WARNING, INHERITED FROM PREP. This table covers 196 players and the
    advanced family (fact_wnba_player_season_advanced) covers 224. This is the
    subset, not the other way round. Never make it the spine of a player-season
    mart: joining the advanced family onto it silently drops 28 players.

    PERCENTAGE SCALE. The source returns these three percentages on a 0-100
    scale (53.0, not 0.530), which is the minority convention in the WNBA set:
    the advanced, four-factors, opponent and all four shot-location endpoints
    return 0-1 fractions, as does standings win_percentage. They are divided by
    100 here so that every rate in the WNBA core layer is a fraction, matching
    NFL fact_wnba_team_season.win_pct. This is the only conversion in the model.
*/

with player_season as (

    select * from {{ ref('stg_wnba__player_season_stats') }}

)

select
    -- keys
    player_season_key,
    player_key,
    player_id,

    -- The team this season line belongs to, which is not always the player's
    -- current team: prep carries TEAM__ID rather than PLAYER__TEAM__ID, and
    -- the two differ on 16 of 196 rows because the player was traded.
    team_key,
    team_id,

    season,
    season_type,
    season_type_name,

    -- The source's count, and the denominator of every average below.
    -- Sometimes impossible -- see header.
    games_played,

    -- ---------------------------------------------------------------------
    -- per-game averages. Nothing below is a total.
    -- ---------------------------------------------------------------------
    minutes_per_game,

    -- shooting. The three percentages arrive 0-100 and become fractions here.
    fgm                                 as field_goals_made_per_game,
    fga                                 as field_goals_attempted_per_game,
    fg_pct / 100                        as field_goal_pct,
    fg3m                                as three_pointers_made_per_game,
    fg3a                                as three_pointers_attempted_per_game,
    fg3_pct / 100                       as three_point_pct,
    ftm                                 as free_throws_made_per_game,
    fta                                 as free_throws_attempted_per_game,
    ft_pct / 100                        as free_throw_pct,

    -- rebounding, playmaking, defence
    reb                                 as rebounds_per_game,
    ast                                 as assists_per_game,
    stl                                 as steals_per_game,
    blk                                 as blocks_per_game,
    turnovers                           as turnovers_per_game,

    -- scoring
    pts                                 as points_per_game

from player_season
