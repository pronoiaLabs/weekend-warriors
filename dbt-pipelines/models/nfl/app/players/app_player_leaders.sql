{{
    config(
        materialized='table'
    )
}}

/*
    app_player_leaders -- season totals with ranks within the position.

    Grain: player x season x season type. Sums of app_player_weeks, per-game
    rates as sum over games, and a rank within (season, season type, position)
    for each of the columns a leaderboard sorts by, 1 = most. The team is the
    one from the player's most recent game of that season type, with the count
    of teams he appeared for (a midseason move shows 2).

    Built from app_player_weeks rather than the fact directly so the
    leaderboard and the player page agree row for row;
    tests/nfl/assert_app_player_leaders_reconcile.sql checks the totals against
    the fact anyway.
*/

with weeks as (

    select * from {{ ref('app_player_weeks') }}

),

last_team as (

    select
        player_key,
        season,
        season_type,
        team_key,
        team_label,
        team_name
    from weeks
    qualify row_number() over (
        partition by player_key, season, season_type order by game_date desc, game_key desc
    ) = 1

),

agg as (

    select
        player_key,
        max(player_id)                                  as player_id,
        max(player_name)                                as player_name,
        max(position)                                   as position,
        max(position_name)                              as position_name,
        max(position_group)                             as position_group,
        season,
        season_type,
        max(season_type_name)                           as season_type_name,
        max(is_postseason)                              as is_postseason,
        count(*)                                        as games,
        count(distinct team_key)                        as teams_count,
        min(game_date)                                  as first_game_date,
        max(game_date)                                  as last_game_date,
        sum(passing_attempts)                           as passing_attempts,
        sum(passing_completions)                        as passing_completions,
        sum(passing_yards)                              as passing_yards,
        sum(passing_touchdowns)                         as passing_touchdowns,
        sum(passing_interceptions)                      as passing_interceptions,
        sum(times_sacked)                               as times_sacked,
        sum(rushing_attempts)                           as rushing_attempts,
        sum(rushing_yards)                              as rushing_yards,
        sum(rushing_touchdowns)                         as rushing_touchdowns,
        max(long_rushing)                               as long_rushing,
        sum(receiving_targets)                          as receiving_targets,
        sum(receptions)                                 as receptions,
        sum(receiving_yards)                            as receiving_yards,
        sum(receiving_touchdowns)                       as receiving_touchdowns,
        max(long_reception)                             as long_reception,
        sum(fumbles)                                    as fumbles,
        sum(fumbles_lost)                               as fumbles_lost,
        sum(scrimmage_yards)                            as scrimmage_yards,
        sum(scrimmage_touchdowns)                       as scrimmage_touchdowns,
        sum(scoring_touchdowns)                         as scoring_touchdowns,
        sum(touches)                                    as touches,
        sum(two_point_conversions)                      as two_point_conversions,
        sum(fanduel_points)                             as fanduel_points,
        sum(draftkings_points)                          as draftkings_points,
        count_if(has_passing)                           as games_with_passing,
        count_if(has_rushing)                           as games_with_rushing,
        count_if(has_receiving)                         as games_with_receiving
    from weeks
    group by player_key, season, season_type

),

rates as (

    select
        a.*,
        round(a.passing_yards / a.games, 1)             as passing_yards_per_game,
        round(a.rushing_yards / a.games, 1)             as rushing_yards_per_game,
        round(a.receiving_yards / a.games, 1)           as receiving_yards_per_game,
        round(a.receptions / a.games, 1)                as receptions_per_game,
        round(a.receiving_targets / a.games, 1)         as targets_per_game,
        round(a.scrimmage_yards / a.games, 1)           as scrimmage_yards_per_game,
        round(a.touches / a.games, 1)                   as touches_per_game,
        round(a.fanduel_points / a.games, 2)            as fanduel_points_per_game,
        round(a.draftkings_points / a.games, 2)         as draftkings_points_per_game,
        iff(a.passing_attempts > 0, round(a.passing_completions / a.passing_attempts, 3), null)
                                                        as completion_pct,
        iff(a.passing_attempts > 0, round(a.passing_yards / a.passing_attempts, 2), null)
                                                        as yards_per_pass_attempt,
        iff(a.rushing_attempts > 0, round(a.rushing_yards / a.rushing_attempts, 2), null)
                                                        as yards_per_rush_attempt,
        iff(a.receptions > 0, round(a.receiving_yards / a.receptions, 2), null)
                                                        as yards_per_reception,
        iff(a.receiving_targets > 0, round(a.receptions / a.receiving_targets, 3), null)
                                                        as catch_rate
    from agg a

)

select
    {{ dbt_utils.generate_surrogate_key(['r.player_key', 'r.season', 'r.season_type']) }}
                                                        as app_player_leaders_key,
    r.player_key,
    r.player_id,
    r.player_name,
    r.position,
    r.position_name,
    r.position_group,
    lt.team_key,
    lt.team_label,
    lt.team_name,
    r.teams_count,
    r.season,
    r.season_type,
    r.season_type_name,
    r.is_postseason,
    r.games,
    r.first_game_date,
    r.last_game_date,
    r.passing_attempts, r.passing_completions, r.passing_yards, r.passing_touchdowns,
    r.passing_interceptions, r.times_sacked, r.completion_pct, r.yards_per_pass_attempt,
    r.rushing_attempts, r.rushing_yards, r.rushing_touchdowns, r.long_rushing, r.yards_per_rush_attempt,
    r.receiving_targets, r.receptions, r.receiving_yards, r.receiving_touchdowns, r.long_reception,
    r.yards_per_reception, r.catch_rate,
    r.fumbles, r.fumbles_lost,
    r.scrimmage_yards, r.scrimmage_touchdowns, r.scoring_touchdowns, r.touches, r.two_point_conversions,
    r.fanduel_points, r.draftkings_points,
    r.games_with_passing, r.games_with_rushing, r.games_with_receiving,
    r.passing_yards_per_game, r.rushing_yards_per_game, r.receiving_yards_per_game,
    r.receptions_per_game, r.targets_per_game, r.scrimmage_yards_per_game, r.touches_per_game,
    r.fanduel_points_per_game, r.draftkings_points_per_game,
    {% set ranked = ['passing_yards', 'passing_touchdowns', 'rushing_yards', 'rushing_touchdowns',
                     'receiving_yards', 'receptions', 'receiving_touchdowns', 'scrimmage_yards',
                     'scoring_touchdowns', 'fanduel_points', 'draftkings_points',
                     'fanduel_points_per_game', 'draftkings_points_per_game'] %}
    {% for col in ranked %}
    rank() over (
        partition by r.season, r.season_type, r.position
        order by r.{{ col }} desc nulls last, r.player_key
    )                                                   as rank_{{ col }},
    {% endfor %}
    count(*) over (partition by r.season, r.season_type, r.position)
                                                        as players_at_position
from rates r
left join last_team lt
    on lt.player_key = r.player_key
   and lt.season = r.season
   and lt.season_type = r.season_type
