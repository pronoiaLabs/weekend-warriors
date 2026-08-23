{{
    config(
        materialized='table'
    )
}}

/*
    app_player_defense_weeks -- a defender's season, one row per game played.

    Grain: player x game (the grain of fact_player_game_defense). The defensive
    box score with identity, team, opponent and the team result, plus running
    season counts. The defensive twin of app_player_weeks; the Explorer reads
    it as the defender sheet.
*/

with defense as (

    select * from {{ ref('fact_player_game_defense') }}

),

players as (

    select * from {{ ref('dim_player') }}

),

games as (

    select * from {{ ref('dim_game') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

team_games as (

    select game_key, team_key, is_win, is_loss, is_tie, points_scored, points_allowed
    from {{ ref('fact_team_game_offense') }}

),

running as (

    select
        player_game_key,
        row_number() over (
            partition by player_key, season, season_type order by week, game_key
        )                                               as games_to_date,
        sum(total_tackles) over (
            partition by player_key, season, season_type order by week, game_key
            rows between unbounded preceding and current row
        )                                               as total_tackles_to_date,
        sum(defensive_sacks) over (
            partition by player_key, season, season_type order by week, game_key
            rows between unbounded preceding and current row
        )                                               as sacks_to_date
    from defense

)

select
    d.player_game_key                                   as app_player_defense_weeks_key,
    d.player_game_key,
    d.game_key,
    d.game_id,
    d.player_key,
    d.player_id,
    p.full_name                                         as player_name,
    p.position_abbreviation                             as position,
    p.position_name,
    p.position_group,
    d.team_key,
    d.team_id,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    iff(d.team_key = g.home_team_key, g.away_team_key, g.home_team_key)
                                                        as opponent_team_key,
    ot.team_abbreviation                                as opponent_label,
    ot.team_full_name                                   as opponent_name,
    d.team_key = g.home_team_key                        as is_home,
    d.season,
    d.week,
    d.season_type,
    g.season_type_name,
    d.is_postseason,
    g.game_date,
    g.game_datetime_et,
    case when tg.is_win then 'W' when tg.is_loss then 'L' when tg.is_tie then 'T' end
                                                        as team_result,
    tg.points_scored                                    as team_points,
    tg.points_allowed                                   as opponent_points,
    r.games_to_date,
    d.total_tackles,
    d.solo_tackles,
    d.assisted_tackles,
    d.tackles_for_loss,
    d.defensive_sacks                                   as sacks,
    d.qb_hits,
    d.passes_defended,
    d.defensive_interceptions                           as interceptions,
    d.interception_yards,
    d.interception_touchdowns,
    d.fumbles_recovered,
    d.fumbles_touchdowns,
    d.takeaways,
    d.defensive_touchdowns,
    r.total_tackles_to_date,
    r.sacks_to_date
from defense d
inner join players p
    on p.player_key = d.player_key
inner join games g
    on g.game_key = d.game_key
inner join running r
    on r.player_game_key = d.player_game_key
left join teams t
    on t.team_key = d.team_key
left join teams ot
    on ot.team_key = iff(d.team_key = g.home_team_key, g.away_team_key, g.home_team_key)
left join team_games tg
    on tg.game_key = d.game_key
   and tg.team_key = d.team_key
