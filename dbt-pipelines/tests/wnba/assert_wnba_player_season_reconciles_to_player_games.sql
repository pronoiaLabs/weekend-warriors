/*
    Cross-check the player season line against the box scores it summarises.

    fact_wnba_player_season is NOT a rollup of fact_wnba_player_game -- it comes from a
    separate season-averages endpoint -- so this is a genuine two-source
    reconciliation and not a restatement of one query. It is also not the
    NFL-style sum-versus-sum check, because every measure on that fact is a
    PER-GAME AVERAGE. Averages are what get compared.

    TWO CHECKS, BECAUSE THE SOURCE FAILS THEM VERY DIFFERENTLY.

    1. THE AVERAGES ARE RIGHT WHEREVER THE DENOMINATORS AGREE.

       Measured read-only over the 196 season rows: on the 129 rows where the
       source's games_played equals the count of non-DNP rows in the box
       scores, the two paths agree to within 0.005 on points, rebounds and
       assists alike -- the largest observed difference is 0.005000 on points,
       0.004815 on rebounds and 0.005000 on assists. That is exactly the
       rounding half-step of a source that publishes two decimal places, so
       the agreement is as complete as it can be. The tolerance is 0.006
       rather than 0.005 only to leave room for binary float representation,
       not to leave room for error.

       The other 67 rows are deliberately out of scope. When the two sources
       disagree about WHICH games a player played, their averages cannot
       agree, and comparing them measures the provider's bookkeeping rather
       than anything this project transforms. Check 2 is what covers those.

    2. games_played IS NOT RECONCILED STRICTLY, BECAUSE IT IS KNOWN WRONG.

       67 of 196 rows disagree with the box-score count, which is far too many
       to assert away and is documented on the fact itself. Only the
       IMPOSSIBLE ones are asserted: rows claiming more games than the leading
       team has played all season. A player cannot appear in more games than
       her club played, so this is a logical bound rather than a chosen
       threshold, and it is derived from fact_wnba_team_game each run rather than
       hardcoded -- the bound loosens on its own as the season progresses.

       Measured today: 18 of 196 rows breach it, topping out at 44 games
       against a league maximum of 33. The count is asserted as an upper bound
       and not exactly, unlike the NFL phase-coverage test, precisely because
       the bound moves: as the league plays more games, some of these rows stop
       being impossible and the count falls on its own. A RISE means new
       corruption and is worth stopping for.

    The two checks report through one result set. Any row returned is a
    failure; the issue column says which check produced it.
*/

{% set average_tolerance = 0.006 %}
{% set max_impossible_games_played = 18 %}

with season_line as (

    select
        player_id,
        season,
        season_type_name,
        games_played,
        points_per_game,
        rebounds_per_game,
        assists_per_game
    from {{ ref('fact_wnba_player_season') }}

),

from_games as (

    -- Measures are NULL on DNP rows by design, so AVG already excludes a
    -- bench night rather than counting it as a zero-point game.
    select
        player_id,
        season,
        season_type_name,
        sum(game_played_count)      as games_played,
        avg(points)                 as points_per_game,
        avg(rebounds)               as rebounds_per_game,
        avg(assists)                as assists_per_game
    from {{ ref('fact_wnba_player_game') }}
    group by player_id, season, season_type_name

),

comparable as (

    -- the honest population: both sources agree on the denominator
    select
        s.player_id,
        s.season,
        s.points_per_game           as season_points,
        g.points_per_game           as game_points,
        s.rebounds_per_game         as season_rebounds,
        g.rebounds_per_game         as game_rebounds,
        s.assists_per_game          as season_assists,
        g.assists_per_game          as game_assists
    from season_line s
    inner join from_games g
        on  s.player_id        = g.player_id
       and  s.season           = g.season
       and  s.season_type_name = g.season_type_name
    where s.games_played = g.games_played

),

average_failures as (

    select
        'average_disagrees_beyond_tolerance'    as issue,
        player_id,
        season,
        'points_per_game'                       as measure,
        season_points                           as season_value,
        game_points                             as game_derived_value
    from comparable
    where abs(season_points - game_points) > {{ average_tolerance }}

    union all

    select
        'average_disagrees_beyond_tolerance',
        player_id,
        season,
        'rebounds_per_game',
        season_rebounds,
        game_rebounds
    from comparable
    where abs(season_rebounds - game_rebounds) > {{ average_tolerance }}

    union all

    select
        'average_disagrees_beyond_tolerance',
        player_id,
        season,
        'assists_per_game',
        season_assists,
        game_assists
    from comparable
    where abs(season_assists - game_assists) > {{ average_tolerance }}

),

league_max_games as (

    -- the logical bound: the most regular-season games any club has played.
    -- Derived, not hardcoded, so it moves with the season.
    select
        season,
        max(team_games) as max_team_games
    from (
        select season, team_id, count(*) as team_games
        from {{ ref('fact_wnba_team_game') }}
        where season_type_name = 'Regular Season'
        group by season, team_id
    )
    group by season

),

impossible_games_played as (

    select count(*) as n
    from season_line s
    inner join league_max_games m
        on s.season = m.season
    where s.games_played > m.max_team_games

),

games_played_failure as (

    select
        'impossible_games_played_above_threshold'   as issue,
        null                                        as player_id,
        null                                        as season,
        'games_played'                              as measure,
        {{ max_impossible_games_played }}           as season_value,
        n                                           as game_derived_value
    from impossible_games_played
    where n > {{ max_impossible_games_played }}

)

select * from average_failures
union all
select * from games_played_failure
