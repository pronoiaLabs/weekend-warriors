{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_team_season_advanced -- the full season-level team profile: box score
    averages, efficiency ratings, the four factors, and the box score allowed.
    Grain: team x season. 15 rows, 2026 regular season only.

    KEPT SEPARATE FROM fact_wnba_team_season BECAUSE COVERAGE DIFFERS BY A FACTOR OF
    NINETEEN. fact_wnba_team_season spans 2008-2026 from the standings endpoint;
    every source here is 2026 only. Folding them into one fact would leave 220
    of 235 rows with every advanced column NULL, and would quietly invite
    year-over-year questions the advanced sources cannot answer. Join the two on
    (team_id, season) when a query needs both.

    A four-way INNER JOIN on (team_id, season) across stg_wnba__team_season_stats,
    _advanced, _four_factors and _opponent. Verified read-only: all four hold
    exactly the same 15 team-seasons, so the inner join returns 15 and loses
    nothing. If a future load breaks that alignment the row count drops
    silently, which is what the unique_combination_of_columns test and the 15-row
    expectation in _facts_season__models.yml are there to make loud.

    TWO GAMES-PLAYED COLUMNS, AND THIS IS NOT A MISTAKE. The advanced,
    four-factors and opponent endpoints agree with each other on games_played,
    wins, losses and win_pct on all 15 rows, so those are taken once from
    advanced. team_season_stats disagrees on 4 of 15 teams -- the two endpoint
    families were captured at different moments and one is a game ahead -- and
    its own count is the denominator of every *_per_game column below. Carrying
    only one would silently mis-scale any total reconstructed from an average,
    so both are published: games_played from the advanced family, and
    box_score_games_played from team_season_stats.

    PER-GAME AVERAGES AND SEASON TOTALS SIT SIDE BY SIDE HERE, so every column
    is named for what it is. Everything ending _per_game comes from
    team_season_stats and is an average (pts of 90.1 is points per game).
    Everything with an opp_ prefix comes from team_season_opponent and is a
    SEASON TOTAL (opp_points of 2,742 is the whole season). possessions and
    minutes_played are totals as well. Nothing here is safely summed across
    teams without checking which kind it is.

    PERCENTAGE SCALE. The WNBA sources disagree with each other: the advanced,
    four-factors and opponent endpoints return 0-1 fractions while
    team_season_stats returns 0-100. Everything is published here as a 0-1
    fraction, which is the scale of the majority of the WNBA sources, of
    stg_wnba__standings.win_percentage, and of NFL fact_wnba_team_season.win_pct.
    The four columns taken from team_season_stats are divided by 100 at the
    point of selection and are the only conversion in this model.

    minutes_played is taken from advanced. The three advanced-family endpoints
    disagree on it for 2 of 15 teams, by a rounding-sized amount, which is not
    worth a second column the way games_played is.
*/

with team_stats as (

    select * from {{ ref('stg_wnba__team_season_stats') }}

),

advanced as (

    select * from {{ ref('stg_wnba__team_season_advanced') }}

),

four_factors as (

    select * from {{ ref('stg_wnba__team_season_four_factors') }}

),

opponent as (

    select * from {{ ref('stg_wnba__team_season_opponent') }}

)

select
    -- keys
    a.team_season_advanced_key,
    a.team_key,
    a.team_id,
    a.season,
    a.season_type_name,

    -- ---------------------------------------------------------------------
    -- record and playing time. Taken from advanced, which agrees exactly with
    -- four_factors and opponent on all 15 rows.
    -- ---------------------------------------------------------------------
    a.games_played,
    a.wins,
    a.losses,
    a.win_pct,
    a.minutes_played,
    a.possessions,

    -- The denominator of every *_per_game column below, and NOT the same
    -- number as games_played on 4 of 15 rows -- see header.
    s.games_played                              as box_score_games_played,

    -- ---------------------------------------------------------------------
    -- box score, PER GAME, from team_season_stats. Averages, never totals.
    -- The three percentages arrive 0-100 and are converted to fractions here.
    -- ---------------------------------------------------------------------
    s.pts                                       as points_per_game,
    s.fgm                                       as field_goals_made_per_game,
    s.fga                                       as field_goals_attempted_per_game,
    s.fg_pct / 100                              as field_goal_pct,
    s.fg3m                                      as three_pointers_made_per_game,
    s.fg3a                                      as three_pointers_attempted_per_game,
    s.fg3_pct / 100                             as three_point_pct,
    s.ftm                                       as free_throws_made_per_game,
    s.fta                                       as free_throws_attempted_per_game,
    s.ft_pct / 100                              as free_throw_pct,
    s.oreb                                      as offensive_rebounds_per_game,
    s.dreb                                      as defensive_rebounds_per_game,
    s.reb                                       as rebounds_per_game,
    s.ast                                       as assists_per_game,
    s.stl                                       as steals_per_game,
    s.blk                                       as blocks_per_game,
    s.turnovers                                 as turnovers_per_game,

    -- ---------------------------------------------------------------------
    -- efficiency and ratings, from advanced. The e_* family is the
    -- model-estimated version of the measured one beside it.
    -- ---------------------------------------------------------------------
    a.effective_field_goal_pct,
    a.true_shooting_pct,
    a.offensive_rating,
    a.defensive_rating,
    a.net_rating,
    a.estimated_offensive_rating,
    a.estimated_defensive_rating,
    a.estimated_net_rating,
    a.pie,
    a.pace,
    a.pace_per40,
    a.estimated_pace,
    a.assist_pct,
    a.assist_ratio,
    a.assist_to_turnover,
    a.team_turnover_pct,
    a.rebound_pct,
    a.offensive_rebound_pct,
    a.defensive_rebound_pct,

    -- ---------------------------------------------------------------------
    -- the four factors ALLOWED. The team's own four factors are already above
    -- under their advanced names (effective_field_goal_pct, team_turnover_pct,
    -- offensive_rebound_pct), which four_factors reproduces exactly on all 15
    -- rows, so only the opp_ half is carried from that source. Without this
    -- half the four factors are an offensive measure only.
    -- ---------------------------------------------------------------------
    f.free_throw_attempt_rate,
    f.opp_effective_field_goal_pct,
    f.opp_team_turnover_pct,
    f.opp_offensive_rebound_pct,
    f.opp_free_throw_attempt_rate,

    -- ---------------------------------------------------------------------
    -- the box score ALLOWED, from opponent. SEASON TOTALS, not averages --
    -- see header. plus_minus is the exception and is this team's own margin.
    -- ---------------------------------------------------------------------
    o.plus_minus,
    o.opp_points,
    o.opp_field_goals_made,
    o.opp_field_goals_attempted,
    o.opp_field_goal_pct,
    o.opp_three_pointers_made,
    o.opp_three_pointers_attempted,
    o.opp_three_point_pct,
    o.opp_free_throws_made,
    o.opp_free_throws_attempted,
    o.opp_free_throw_pct,
    o.opp_rebounds,
    o.opp_offensive_rebounds,
    o.opp_defensive_rebounds,
    o.opp_assists,
    o.opp_turnovers,
    o.opp_steals,
    o.opp_blocks,
    o.opp_blocks_against,
    o.opp_personal_fouls,
    o.opp_personal_fouls_drawn

from advanced a
inner join team_stats s
    on  a.team_id = s.team_id
    and a.season  = s.season
inner join four_factors f
    on  a.team_id = f.team_id
    and a.season  = f.season
inner join opponent o
    on  a.team_id = o.team_id
    and a.season  = o.season
