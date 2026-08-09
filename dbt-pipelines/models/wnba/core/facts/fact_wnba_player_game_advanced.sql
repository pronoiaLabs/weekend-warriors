{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_player_game_advanced -- advanced player box score.
    Grain: player x game. 5,569 rows. 56 measures, curated from the 74 that
    stg_wnba__player_game_advanced flattens out of the source's five nested
    groups. The 18 left behind are four near-duplicates of published tempo and
    load metrics (pace_per40, estimated_pace, assist_ratio,
    estimated_usage_pct), eight scoring shares that split an already-published
    total by 2pt and 3pt, and six usage shares that are either a made rate
    whose attempted twin is published or a fouls / blocks-allowed share. All
    18 remain in the staging view.

    IT IS A LEFT-JOIN PARTNER TO fact_wnba_player_game, NEVER AN INNER ONE.
    182 of that fact's 5,751 rows have no row here, and they split two ways:

      *  93 sit in four games with no advanced coverage at all -- 24832 and
         24833 on 2026-06-07, 24896 on 2026-06-30, and the All-Star game
         24955 on 2026-07-26. Advanced covers 233 games against the basic box
         score's 237. The two 2026-08-08 games missing from the basic box are
         missing here too, so they do not add to this count.
      *  89 sit in games that ARE covered, of which 86 are DNPs and 3 are
         played rows. Individual gaps, not a missing load.

    Nothing here is invented in the other direction: every one of the 5,569
    rows matches a player_stats row, verified, so the is_dnp join below is a
    LEFT JOIN only to keep a future gap from silently dropping a row.

    THE DNP TRAP IS THE OPPOSITE OF THE ONE IN fact_wnba_player_game, AND IT IS THE
    REASON is_dnp IS REPUBLISHED HERE. 975 of the 1,076 DNP player-games have
    an advanced row, and that row is not empty: offensive_rating is 0 on 973
    of them, pie on 974, usage_pct on 974, possessions on 965. The source
    writes a real zero where the basic box score writes a NULL. So where
    avg(points) on fact_wnba_player_game correctly ignores bench nights,
    avg(offensive_rating) here silently averages 973 zeros in and reports
    every player as worse than she is. FILTER ON is_dnp = false before
    averaging anything in this fact. The zeros are left as loaded rather than
    nulled out, because they are what the source said and rewriting them here
    would hide the discrepancy between the two facts instead of naming it.

    EVERY MEASURE IS A RATE, A RATING OR A SHARE except the misc block at the
    bottom, which is counts. None of the rates is additive across games.

    TWO EFFECTIVE FIELD GOAL COLUMNS, BOTH KEPT, AND THEY ARE DIFFERENT
    NUMBERS. effective_field_goal_pct is the player's own rate.
    four_factors_effective_field_goal_pct keeps its group qualifier because it
    is not: the two disagree on 4,469 of the 5,569 rows, and the four-factors
    value does not match the player's team row either (44 of 5,569), so it is
    the four-factors context around the player, consistent with the opp_*
    columns sitting beside it in that group. Do not treat them as
    interchangeable and do not drop the qualifier. Note that on
    fact_wnba_team_game_advanced this duplication collapses -- a team has no
    on-court context distinct from itself -- so the team fact has one eFG.

    THE opp_* COLUMNS ARE PER-PLAYER, NOT THE OPPONENT'S TEAM LINE. Measured:
    all 466 game x team groups show more than one distinct value of each opp_*
    metric across their players, so these are the opponent's production while
    that player was on the floor. Read them as an on/off defensive signal, not
    as the opponent's box score, which is on fact_wnba_team_game_advanced.
*/

with advanced as (

    select * from {{ ref('stg_wnba__player_game_advanced') }}

),

player_stats as (

    -- is_dnp only. See the header: without it, averaging any rating here is
    -- wrong by roughly a thousand zeros.
    select
        player_game_key,
        is_dnp
    from {{ ref('stg_wnba__player_stats') }}

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
    a.player_game_advanced_key,

    -- same hash inputs as fact_wnba_player_game.player_game_key, so the two facts
    -- join on it directly
    {{ dbt_utils.generate_surrogate_key(['a.game_id', 'a.player_id']) }} as player_game_key,
    a.game_key,
    a.game_id,
    a.player_key,
    a.player_id,
    a.team_key,
    a.team_id,
    g.date_key,

    -- ---------------------------------------------------------------
    -- degenerate dimensions / context, taken from dim_wnba_game so this fact and
    -- fact_wnba_player_game cannot disagree about what season a game was in
    -- ---------------------------------------------------------------
    g.game_date,
    g.season,
    g.season_type_name,
    g.is_postseason,

    -- ---------------------------------------------------------------
    -- playing time. minutes_played is NULL on nearly every DNP row here
    -- while the ratings below are 0, which is exactly why is_dnp is carried.
    -- ---------------------------------------------------------------
    a.minutes_played,
    ps.is_dnp,

    -- ---------------------------------------------------------------
    -- four factors -- context around the player, including the opponent's
    -- side. See the header on the eFG qualifier and on opp_*.
    -- ---------------------------------------------------------------
    a.free_throw_attempt_rate,
    a.team_turnover_pct,
    a.four_factors_effective_field_goal_pct,
    a.opp_free_throw_attempt_rate,
    a.opp_team_turnover_pct,
    a.opp_offensive_rebound_pct,
    a.opp_effective_field_goal_pct,

    -- ---------------------------------------------------------------
    -- efficiency and tempo
    -- ---------------------------------------------------------------
    a.pie,
    a.pace,
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
    -- ball movement, possession and load
    -- ---------------------------------------------------------------
    a.assist_pct,
    a.assist_to_turnover,
    a.turnover_ratio,
    a.usage_pct,

    -- ---------------------------------------------------------------
    -- rebounding
    -- ---------------------------------------------------------------
    a.rebound_pct,
    a.offensive_rebound_pct,
    a.defensive_rebound_pct,

    -- ---------------------------------------------------------------
    -- scoring shares -- how the player's own points were distributed
    -- ---------------------------------------------------------------
    a.points_2pt_pct,
    a.points_3pt_pct,
    a.points_paint_pct,
    a.points_free_throw_pct,
    a.points_fast_break_pct,
    a.points_off_turnovers_pct,
    a.assisted_fgm_pct,

    -- ---------------------------------------------------------------
    -- usage shares -- the player's slice of her team's activity, so these
    -- sum to roughly 100 across a team's players in one game. The made/
    -- attempted pairs are published as attempted only: the made share is
    -- the attempted share reweighted by accuracy, which true_shooting_pct
    -- already says better.
    -- ---------------------------------------------------------------
    a.points_pct,
    a.assists_pct,
    a.rebounds_total_pct,
    a.rebounds_offensive_pct,
    a.rebounds_defensive_pct,
    a.turnovers_pct,
    a.steals_pct,
    a.blocks_pct,
    a.field_goals_attempted_pct,
    a.three_pointers_attempted_pct,
    a.free_throws_attempted_pct,

    -- ---------------------------------------------------------------
    -- counting stats the basic box score does not carry. These DO sum.
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
left join player_stats ps
    on a.player_game_advanced_key = ps.player_game_key
