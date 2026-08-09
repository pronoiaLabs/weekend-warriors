{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_team_game_advanced -- advanced team box score. Grain: team x game.

    466 rows = 233 games x 2 teams. 49 measures, curated from the 74
    stg_wnba__team_game_advanced flattens out of the source's five nested
    groups.

    IT DOES NOT COVER EVERY GAME fact_wnba_team_game COVERS. 233 of the 239 games
    with a result have advanced rows; six do not, and they are the two
    2026-08-08 games that have no basic box score either (24989, 24990) plus
    24832 and 24833 on 2026-06-07, 24896 on 2026-06-30, and the All-Star game
    24955 on 2026-07-26. So this fact is joined to fact_wnba_team_game from the
    left, never the other way, and a count over it is 24 team-games short of
    the schedule. Nothing here is filtered: all 466 source rows land, and all
    466 already sit on games with a result, so no scope rule is applied and
    none is needed.

    THE 74 MEASURES ARE NOT ALL PUBLISHED. 49 are, and the 25 that are not
    fall into three groups. The 17 usage shares go in full: they express a
    player's share of the team's activity, so at team grain each one is near
    100 by construction and carries no information. usage_pct and
    estimated_usage_pct in the advanced group go with them. estimated_pace
    goes because pace and pace_per40 already say it. The last five are the
    four 2pt/3pt splits of the assisted and unassisted scoring shares,
    dropped in favour of the assisted_fgm_pct / unassisted_fgm_pct totals
    beside them, plus field_goals_attempted_2pt_pct, which is 100 minus the
    3pt share that is kept. Everything dropped is still in the staging view.

    EVERY MEASURE HERE IS A RATE OR A RATING, so almost nothing is additive.
    Summing offensive_rating across games is meaningless; average it, and
    weight by possessions when the games differ in length. The misc block at
    the bottom is the exception -- those are counts and do sum.

    TEAM_TURNOVER_PCT AND ESTIMATED_TEAM_TURNOVER_PCT ARE BOTH KEPT and are
    not a duplicate: they differ on all 466 rows, which is what "estimated"
    means. The genuine duplicates were resolved upstream, where the four
    factors copies of eFG and offensive rebound rate were verified identical
    to the advanced ones and dropped. Note that this is the opposite outcome
    from fact_wnba_player_game_advanced, where the two eFG readings disagree on
    4,469 of 5,569 rows and both survive.
*/

with advanced as (

    select * from {{ ref('stg_wnba__team_game_advanced') }}

),

games as (

    select
        game_key,
        date_key,
        season,
        season_type_name,
        is_postseason,
        game_date
    from {{ ref('dim_wnba_game') }}

)

select
    -- ---------------------------------------------------------------
    -- keys
    -- ---------------------------------------------------------------
    a.team_game_advanced_key,

    -- same hash inputs as fact_wnba_team_game.team_game_key, so the two facts
    -- join on it directly
    {{ dbt_utils.generate_surrogate_key(['a.game_id', 'a.team_id']) }}  as team_game_key,
    a.game_key,
    a.game_id,
    a.team_key,
    a.team_id,
    g.date_key,

    -- ---------------------------------------------------------------
    -- degenerate dimensions / context, taken from dim_wnba_game so this fact and
    -- fact_wnba_team_game cannot disagree about what season a game was in
    -- ---------------------------------------------------------------
    g.game_date,
    g.season,
    g.season_type_name,
    g.is_postseason,

    -- ~199 minutes per team per game: five players on the floor, so this is
    -- roughly 5x a player's figure and is not comparable to one.
    a.minutes_played,

    -- ---------------------------------------------------------------
    -- four factors -- the team's own rates plus the opponent's. eFG and
    -- offensive rebound rate live in the advanced block below, where the
    -- surviving copy sits.
    -- ---------------------------------------------------------------
    a.free_throw_attempt_rate,
    a.team_turnover_pct,
    a.opp_free_throw_attempt_rate,
    a.opp_team_turnover_pct,
    a.opp_offensive_rebound_pct,
    a.opp_effective_field_goal_pct,

    -- ---------------------------------------------------------------
    -- efficiency and tempo
    -- ---------------------------------------------------------------
    a.pie,
    a.pace,
    a.pace_per40,
    a.possessions,
    a.offensive_rating,
    a.defensive_rating,
    a.net_rating,
    a.estimated_offensive_rating,
    a.estimated_defensive_rating,
    a.estimated_net_rating,
    a.true_shooting_pct,
    a.effective_field_goal_pct,

    -- ---------------------------------------------------------------
    -- ball movement and possession
    -- ---------------------------------------------------------------
    a.assist_ratio,
    a.assist_pct,
    a.assist_to_turnover,
    a.turnover_ratio,
    a.estimated_team_turnover_pct,

    -- ---------------------------------------------------------------
    -- rebounding
    -- ---------------------------------------------------------------
    a.rebound_pct,
    a.offensive_rebound_pct,
    a.defensive_rebound_pct,

    -- ---------------------------------------------------------------
    -- scoring shares -- how the team's points and shots were distributed.
    -- Percentages of the team's own total, so they do not sum across games.
    -- ---------------------------------------------------------------
    a.points_2pt_pct,
    a.points_3pt_pct,
    a.points_paint_pct,
    a.points_midrange_2pt_pct,
    a.points_free_throw_pct,
    a.points_fast_break_pct,
    a.points_off_turnovers_pct,
    a.assisted_fgm_pct,
    a.unassisted_fgm_pct,
    a.field_goals_attempted_3pt_pct,

    -- ---------------------------------------------------------------
    -- counting stats the basic box score does not carry. These DO sum.
    -- The opp_* pairs make a defensive profile readable off one row.
    -- ---------------------------------------------------------------
    a.blocks,
    a.blocks_against,
    a.fouls_personal,
    a.fouls_drawn,
    a.points_paint,
    a.points_fast_break,
    a.points_off_turnovers,
    a.points_second_chance,
    a.opp_points_paint,
    a.opp_points_fast_break,
    a.opp_points_off_turnovers,
    a.opp_points_second_chance

from advanced a
inner join games g
    on a.game_key = g.game_key
