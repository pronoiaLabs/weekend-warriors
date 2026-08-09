{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_player_season_advanced -- the full advanced season profile: efficiency,
    ratings, pace, usage, shot and scoring distribution, team share, and
    defence. Grain: player x season. 224 rows, 2026 regular season only.

    A five-way INNER JOIN on (player_id, season) across
    stg_wnba__player_season_{advanced, misc, scoring, usage, defense}.

    THE INNER JOIN IS HONEST BECAUSE THE FIVE SOURCES COVER AN IDENTICAL
    POPULATION. Verified read-only in prod: each holds exactly 224 rows and the
    five-way inner join returns 224, so no player is dropped and the join
    cannot fan out. It is written as an inner join rather than a chain of left
    joins because a left join would hide a future coverage break as a row full
    of NULLs, while the inner join makes it a silent row-count drop -- which is
    exactly what
    tests/wnba/assert_wnba_advanced_family_is_complete.sql exists to catch.
    That test is the price of the inner join, and it is worth paying: it fires
    the moment the assumption stops holding.

    THIS IS THE SPINE OF THE PLAYER-SEASON MART, NOT fact_wnba_player_season. That
    fact covers 196 players and this one covers 224. Build from here and left
    join the basic line on, never the other way round.

    THE FIVE SOURCES DISAGREE WITH EACH OTHER ON THEIR SHARED COLUMNS, so every
    duplicated measure is taken from exactly one named source and the choice is
    recorded beside it. Measured over the 224 rows: games_played agrees across
    all five on only 204, blocks agrees between misc and defense on 217, the
    opponent points-by-origin block agrees on 204. The endpoints were read at
    slightly different moments and one is a game ahead of another. Where they
    disagree the difference is a game's worth of production, not a
    transformation error.

    MINUTES MEANS TWO DIFFERENT THINGS ACROSS THE FIVE, and this is the trap
    worth knowing about. advanced and scoring return MINUTES PER GAME (27.6);
    misc, usage and defense return SEASON TOTAL MINUTES (911.7). The two agree
    on exactly 1 of 224 rows, which is coincidence and not agreement. Both are
    published, named for what they are: minutes_per_game and
    total_minutes_played. usage's copy of the total is rounded to a whole
    minute, so the total is taken from misc, which is not.

    TEAM IS AN APPROXIMATION AND THE FACT SAYS SO. team_key and
    team_abbreviation are stamped from dim_wnba_player, which knows only each
    player's CURRENT team -- the WNBA source carries no team history at all.
    10 of these 224 players have team_count = 2 and played for two teams this
    season, so for them this attributes the whole season to whichever club they
    finished with. The five sources' own team ids agree with dim_wnba_player on 223
    of 224 rows, so the stamp changes almost nothing today; it is used because
    it is the one team attribution the rest of the mart shares. For a
    historically accurate per-game team, use fact_wnba_player_game.team_id.
    No team_id column is published here on purpose: there is no source id that
    is guaranteed to match the dimension's current team, and publishing a key
    and an id that can disagree inside one row is worse than publishing one.

    PERCENTAGE SCALE. Everything on these five endpoints already arrives as a
    0-1 fraction, so unlike fact_wnba_player_season there is no conversion in this
    model. Note that the _pct suffix covers three different denominators here:
    a shooting rate (field_goal_pct), a share of the player's own output
    (points_paint_pct, from scoring), and a share of the TEAM's output
    (rebounds_defensive_pct, from usage). They are not interchangeable.
*/

with advanced as (

    select * from {{ ref('stg_wnba__player_season_advanced') }}

),

misc as (

    select * from {{ ref('stg_wnba__player_season_misc') }}

),

scoring as (

    select * from {{ ref('stg_wnba__player_season_scoring') }}

),

usage as (

    select * from {{ ref('stg_wnba__player_season_usage') }}

),

defense as (

    select * from {{ ref('stg_wnba__player_season_defense') }}

),

players as (

    select
        player_id,
        current_team_key,
        current_team_abbreviation
    from {{ ref('dim_wnba_player') }}

)

select
    -- keys
    a.player_season_advanced_key,
    a.player_key,
    a.player_id,

    -- current team, not season team -- see header
    p.current_team_key                          as team_key,
    p.current_team_abbreviation                 as team_abbreviation,

    a.season,
    a.season_type_name,

    -- ---------------------------------------------------------------------
    -- playing time and record, all from advanced. The other four disagree on
    -- games_played for 20 of 224 rows -- see header.
    -- ---------------------------------------------------------------------
    a.games_played,
    a.wins,
    a.losses,
    a.win_pct,
    a.age,
    -- 2 for the 10 players who changed clubs this season
    a.team_count,

    -- the two minutes columns are different units, not duplicates
    a.minutes_played                            as minutes_per_game,
    m.minutes_played                            as total_minutes_played,

    -- ---------------------------------------------------------------------
    -- shooting volume and efficiency, from advanced
    -- ---------------------------------------------------------------------
    a.field_goals_attempted,
    a.field_goals_made,
    a.field_goals_attempted_per_game,
    a.field_goals_made_per_game,
    a.field_goal_pct,
    a.effective_field_goal_pct,
    a.true_shooting_pct,

    -- ---------------------------------------------------------------------
    -- ratings. e_* is the model-estimated version of the measured one beside
    -- it; sp_work_* is the tracking-derived version.
    -- ---------------------------------------------------------------------
    a.offensive_rating,
    a.defensive_rating,
    a.net_rating,
    a.estimated_offensive_rating,
    a.estimated_defensive_rating,
    a.estimated_net_rating,
    a.sp_work_offensive_rating,
    a.sp_work_defensive_rating,
    a.sp_work_net_rating,
    a.pie,

    -- ---------------------------------------------------------------------
    -- pace and possessions, from advanced
    -- ---------------------------------------------------------------------
    a.pace,
    a.pace_per40,
    a.estimated_pace,
    a.sp_work_pace,
    a.possessions,

    -- ---------------------------------------------------------------------
    -- usage, playmaking and rebounding RATES, from advanced. Denominator is
    -- opportunity, not the team total.
    -- ---------------------------------------------------------------------
    a.usage_pct,
    a.estimated_usage_pct,
    a.assist_pct,
    a.assist_ratio,
    a.assist_to_turnover,
    a.team_turnover_pct,
    a.estimated_turnover_pct,
    a.rebound_pct,
    a.offensive_rebound_pct,
    a.defensive_rebound_pct,

    -- ---------------------------------------------------------------------
    -- fouls, blocks against and points by origin, from misc. Season totals.
    -- ---------------------------------------------------------------------
    m.personal_fouls,
    m.personal_fouls_drawn,
    m.blocks_against,
    m.points_paint,
    m.points_fast_break,
    m.points_off_turnovers,
    m.points_second_chance,
    m.fantasy_points,

    -- The same four allowed. Taken from misc rather than defense, which
    -- carries the same block and agrees on 204 of 224 rows.
    m.opp_points_paint,
    m.opp_points_fast_break,
    m.opp_points_off_turnovers,
    m.opp_points_second_chance,

    -- ---------------------------------------------------------------------
    -- distribution of the PLAYER'S OWN points and shots, from scoring.
    -- Denominator is the player, not the team.
    -- ---------------------------------------------------------------------
    s.points_2pt_pct,
    s.points_3pt_pct,
    s.points_midrange_2pt_pct,
    s.points_paint_pct,
    s.points_free_throw_pct,
    s.points_fast_break_pct,
    s.points_off_turnovers_pct,
    s.field_goals_attempted_2pt_pct,
    s.field_goals_attempted_3pt_pct,
    s.assisted_2pt_pct,
    s.assisted_3pt_pct,
    s.assisted_fgm_pct,
    s.unassisted_2pt_pct,
    s.unassisted_3pt_pct,
    s.unassisted_fgm_pct,

    -- ---------------------------------------------------------------------
    -- share of the TEAM'S output, from usage. Same _pct suffix, different
    -- denominator from everything above.
    -- ---------------------------------------------------------------------
    u.points_pct,
    u.field_goals_made_pct,
    u.field_goals_attempted_pct,
    u.three_pointers_made_pct,
    u.three_pointers_attempted_pct,
    u.free_throws_made_pct,
    u.free_throws_attempted_pct,
    u.assists_pct,
    u.turnovers_pct,
    u.rebounds_total_pct,
    u.rebounds_offensive_pct,
    u.rebounds_defensive_pct,
    u.steals_pct,
    u.blocks_pct,
    u.blocks_allowed_pct,
    u.personal_fouls_pct,
    u.personal_fouls_drawn_pct,

    -- ---------------------------------------------------------------------
    -- defensive counting stats and win shares, from defense. blocks is taken
    -- here rather than from misc, which agrees on 217 of 224.
    -- ---------------------------------------------------------------------
    d.defensive_rebounds,
    d.steals,
    d.blocks,
    d.defensive_win_shares,
    d.defensive_win_shares_raw

from advanced a
inner join misc m
    on  a.player_id = m.player_id
    and a.season    = m.season
inner join scoring s
    on  a.player_id = s.player_id
    and a.season    = s.season
inner join usage u
    on  a.player_id = u.player_id
    and a.season    = u.season
inner join defense d
    on  a.player_id = d.player_id
    and a.season    = d.season
left join players p
    on  a.player_id = p.player_id
