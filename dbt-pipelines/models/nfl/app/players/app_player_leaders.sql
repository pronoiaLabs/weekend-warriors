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

    Usage aggregates each carry their honest computation, and the names say
    which: target_share is a ratio of sums (player targets over his team's
    targets in his games, BDL-derived so coverage is full), snap_share is the
    one sanctioned snap ratio (sum of Sleeper snaps over team snaps, NULL when
    no Sleeper games -- games_with_sleeper says why), and air_yards_share_avg
    is an AVERAGE of per-game shares because no team air-yards denominator
    exists anywhere in the warehouse; the _avg suffix marks the convention.
    Canonical PPR is nflverse (ppr_points); its per-game rate divides by
    games_with_nflverse, the games that actually carry the number.

    The riser window (the finder's rail): average target share over the last
    three played games vs all earlier games of the season type, delta NULL
    unless both windows hold at least two observations. The next-game block
    is current-state by construction -- populated only where the team's next
    non-completed game falls in the row's own (season, season type), so a
    historical row never shows a future fixture; next_opp_allowed_rank reads
    app_team_allowed (1 = allows the MOST to the position, soft matchup) for
    the position's headline stat, falling back one season until the current
    one has games.
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
        count_if(has_receiving)                         as games_with_receiving,
        count_if(has_nflverse)                          as games_with_nflverse,
        count_if(has_sleeper)                           as games_with_sleeper,
        sum(team_targets)                               as team_targets,
        avg(air_yards_share)                            as air_yards_share_avg,
        sum(off_snaps)                                  as off_snaps,
        sum(team_off_snaps)                             as team_off_snaps,
        sum(passing_epa)                                as passing_epa,
        sum(rushing_epa)                                as rushing_epa,
        sum(receiving_epa)                              as receiving_epa,
        sum(ppr_points)                                 as ppr_points,
        sum(sleeper_ppr_points)                         as sleeper_ppr_points
    from weeks
    group by player_key, season, season_type

),

-- the finder's riser window: recent target share vs the season before it
riser as (

    select
        player_key,
        season,
        season_type,
        round(avg(iff(recency <= 3, target_share, null)), 3)
                                                        as target_share_last3,
        count_if(recency <= 3 and target_share is not null)
                                                        as last3_share_games,
        round(avg(iff(recency > 3, target_share, null)), 3)
                                                        as target_share_prior,
        count_if(recency > 3 and target_share is not null)
                                                        as prior_share_games
    from (
        select
            player_key,
            season,
            season_type,
            target_share,
            row_number() over (
                partition by player_key, season, season_type
                order by game_date desc, game_key desc
            )                                           as recency
        from weeks
    )
    group by 1, 2, 3

),

-- each team's next non-completed game (the status board's pattern)
next_game as (

    select
        t.team_key,
        g.game_key,
        g.game_datetime_et,
        g.season,
        g.season_type,
        g.week,
        iff(g.home_team_key = t.team_key, g.away_team_key, g.home_team_key)
                                                        as opponent_team_key,
        g.home_team_key = t.team_key                    as is_home
    from {{ ref('dim_team') }} t
    inner join {{ ref('dim_game') }} g
        on (g.home_team_key = t.team_key or g.away_team_key = t.team_key)
       and not g.is_completed
    qualify row_number() over (partition by t.team_key order by g.game_datetime) = 1

),

allowed as (

    select season, season_type, team_key, position, stat_key,
           allowed_rank, teams_ranked
    from {{ ref('app_team_allowed') }}

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
                                                        as catch_rate,
        round(a.receiving_targets / nullif(a.team_targets, 0), 3)
                                                        as target_share,
        -- clamped at 1: Sleeper's team snap totals can undercount by a snap
        least(round(a.off_snaps / nullif(a.team_off_snaps, 0), 3), 1)
                                                        as snap_share,
        round(a.ppr_points / nullif(a.games_with_nflverse, 0), 2)
                                                        as ppr_points_per_game
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
    r.games_with_nflverse, r.games_with_sleeper,
    r.passing_yards_per_game, r.rushing_yards_per_game, r.receiving_yards_per_game,
    r.receptions_per_game, r.targets_per_game, r.scrimmage_yards_per_game, r.touches_per_game,
    r.fanduel_points_per_game, r.draftkings_points_per_game,
    dp.headshot_url,
    r.target_share,
    round(r.air_yards_share_avg, 3)                     as air_yards_share_avg,
    r.snap_share,
    round(r.passing_epa, 1)                             as passing_epa,
    round(r.rushing_epa, 1)                             as rushing_epa,
    round(r.receiving_epa, 1)                           as receiving_epa,
    round(r.ppr_points, 2)                              as ppr_points,
    r.ppr_points_per_game,
    round(r.sleeper_ppr_points, 2)                      as sleeper_ppr_points,
    ri.target_share_last3,
    ri.last3_share_games,
    ri.target_share_prior,
    ri.prior_share_games,
    iff(ri.last3_share_games >= 2 and ri.prior_share_games >= 2,
        round(ri.target_share_last3 - ri.target_share_prior, 3), null)
                                                        as target_share_delta,
    ng.game_key                                         as next_game_key,
    ng.opponent_team_key                                as next_opponent_team_key,
    nt.team_abbreviation                                as next_opponent_label,
    ng.is_home                                          as next_is_home,
    ng.game_datetime_et                                 as next_game_datetime_et,
    coalesce(al_now.allowed_rank, al_prior.allowed_rank)
                                                        as next_opp_allowed_rank,
    coalesce(al_now.teams_ranked, al_prior.teams_ranked)
                                                        as next_opp_allowed_teams_ranked,
    case
        when al_now.allowed_rank is not null then r.season
        when al_prior.allowed_rank is not null then r.season - 1
    end                                                 as next_opp_allowed_season,
    {% set ranked = ['passing_yards', 'passing_touchdowns', 'rushing_yards', 'rushing_touchdowns',
                     'receiving_yards', 'receptions', 'receiving_touchdowns', 'scrimmage_yards',
                     'scoring_touchdowns', 'fanduel_points', 'draftkings_points',
                     'fanduel_points_per_game', 'draftkings_points_per_game',
                     'target_share', 'snap_share', 'ppr_points', 'ppr_points_per_game',
                     'receiving_epa'] %}
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
left join {{ ref('dim_player') }} dp
    on dp.player_key = r.player_key
left join riser ri
    on ri.player_key = r.player_key
   and ri.season = r.season
   and ri.season_type = r.season_type
left join next_game ng
    on ng.team_key = lt.team_key
   and ng.season = r.season
   and ng.season_type = r.season_type
left join {{ ref('dim_team') }} nt
    on nt.team_key = ng.opponent_team_key
left join allowed al_now
    on al_now.team_key = ng.opponent_team_key
   and al_now.season = r.season
   and al_now.season_type = r.season_type
   and al_now.position = r.position
   and al_now.stat_key = case r.position
                             when 'QB' then 'passing_yards'
                             when 'RB' then 'rushing_yards'
                             when 'WR' then 'receiving_yards'
                             when 'TE' then 'receiving_yards'
                         end
left join allowed al_prior
    on al_prior.team_key = ng.opponent_team_key
   and al_prior.season = r.season - 1
   and al_prior.season_type = r.season_type
   and al_prior.position = r.position
   and al_prior.stat_key = case r.position
                               when 'QB' then 'passing_yards'
                               when 'RB' then 'rushing_yards'
                               when 'WR' then 'receiving_yards'
                               when 'TE' then 'receiving_yards'
                           end
