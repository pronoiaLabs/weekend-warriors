{{
    config(
        materialized='table'
    )
}}

/*
    fact_team_game_offense -- one row per team per COMPLETED game. Grain: team x game.

    OFFENSE, by name and by content. Every box-score column here is what THIS
    team's offense did: its yards, attempts, first downs, third and fourth down
    conversions, red zone trips, drives, possession time, the sacks its
    quarterback took (sacks_allowed), its turnovers and its penalties. The only
    defensive readings are points_allowed and the provider's defensive_touchdowns.
    The same game seen from this team's defense (yards allowed, takeaways,
    sacks recorded, pressure and coverage counts) is fact_team_game_defense,
    a 1:1 twin on team_game_key. The game result (points, margin, win/loss/tie)
    lives here rather than on the twin because records aggregate from one row
    per team-game, and this is that row.

    Two rows per completed game, exactly. Scheduled games are filtered out at
    the games CTE: a fact row asserts "this team played this game and here is
    what happened", and an unplayed game has no such row. Without the filter,
    every scheduled game becomes two NULL-score rows that inflate game counts
    and averages (and would mint fake ties if the provider ever writes 0-0
    placeholders). The full slate including unplayed games lives on dim_game,
    which carries is_completed for exactly this reason.

    This is the unpivot of stg_nfl__games (which stores home and away side by
    side) into the standard sports-star shape, with the team box score joined on.
    Every row answers "how did THIS team do in THIS game", carrying
    opponent_team_key so opponent analysis needs no self-join, and
    points_scored / points_allowed rather than home/away scores so that records
    and splits are plain aggregations.

    The unpivot is a UNION ALL of two selects over the same completed-games
    set, not a join, so it cannot fan out: exactly two rows per game by
    construction.

    Box score coverage: team_stats trails the fact by a handful -- some games have no
    team_stats. The join is a LEFT JOIN, so those four team-game rows exist with
    the result populated and every box-score measure NULL. Losing the games
    entirely would be worse than carrying the NULLs.

    Season scope is all three season types. season_type is on dim_game and
    dim_season_week; filter there rather than assuming regular season.

    EPA BLOCK (the retired fact_team_game_epa's offense half, folded in).
    Scrimmage plays from nflverse play-by-play rolled up to this same grain:
    play_type in (pass, run) with a non-NULL EPA (measured 2025: 34,632 of
    48,771 rows; qb_dropback adds nothing beyond those two types). Special
    teams, penalties-only and no-plays are out. The fold is a lossless 1:1
    column concat: every non-preseason team-game row has its EPA row on the
    same team_game_key (measured Aug 2026: 1,710 of 1,710) and only the
    preseason rows carry NULLs, nflverse publishing no preseason play-by-play
    -- has_nflverse flags it. The same plays read from the defending side are
    the def_* block on fact_team_game_defense, taken from THIS fact's
    opponent row so the two can never disagree.

    Rates in the EPA block are computed from this grain's own sums and cannot
    be re-aggregated; anything at another grain should go back to the additive
    columns -- off_plays, dropbacks, carries, the epa sums, success_plays,
    explosive_plays, early_down_plays / early_down_success_plays and
    pass_over_expected_sum / xpass_plays (the same additive contract
    fact_team_game_situation carries). proe is pass rate over expected:
    mean(pass - xpass) on scrimmage plays. Play-level detail deliberately
    stays in stg_nfl__nflverse_pbp; this is the modeling surface.
*/

with games as (

    select * from {{ ref('stg_nfl__games') }}
    where is_completed          -- scheduled games have no fact rows, see header

),

-- ---------------------------------------------------------------------------
-- Unpivot: one select per side, unioned. Two rows per game, guaranteed.
-- ---------------------------------------------------------------------------
home_side as (

    select
        game_key,
        game_id,
        game_date,
        season,
        week,
        season_type,
        is_postseason,
        went_to_overtime,

        home_team_key           as team_key,
        home_team_id            as team_id,
        away_team_key           as opponent_team_key,
        away_team_id            as opponent_team_id,
        true                    as is_home,

        home_team_score         as points_scored,
        away_team_score         as points_allowed,

        home_team_q1            as points_q1,
        home_team_q2            as points_q2,
        home_team_q3            as points_q3,
        home_team_q4            as points_q4,
        home_team_ot            as points_ot

    from games

),

away_side as (

    select
        game_key,
        game_id,
        game_date,
        season,
        week,
        season_type,
        is_postseason,
        went_to_overtime,

        away_team_key           as team_key,
        away_team_id            as team_id,
        home_team_key           as opponent_team_key,
        home_team_id            as opponent_team_id,
        false                   as is_home,

        away_team_score         as points_scored,
        home_team_score         as points_allowed,

        away_team_q1            as points_q1,
        away_team_q2            as points_q2,
        away_team_q3            as points_q3,
        away_team_q4            as points_q4,
        away_team_ot            as points_ot

    from games

),

team_games as (

    select * from home_side
    union all
    select * from away_side

),

box_score as (

    select * from {{ ref('stg_nfl__team_stats') }}

),

-- ---------------------------------------------------------------------------
-- EPA block: scrimmage plays only (see header), rolled up per possessing
-- team, then mapped onto this fact's (game_id, team_id) grain through
-- bridge_game_ids.
-- ---------------------------------------------------------------------------
epa_plays as (

    select
        nflverse_game_id,
        posteam,
        epa,
        success,
        yards_gained,
        pass,
        rush,
        down,
        cpoe,
        xpass
    from {{ ref('stg_nfl__nflverse_pbp') }}
    where play_type in ('pass', 'run')
      and epa is not null
      and posteam is not null

),

epa_offense as (

    select
        nflverse_game_id,
        posteam                                         as team,
        count(*)                                        as off_plays,
        sum(epa)                                        as off_epa,
        sum(epa) / count(*)                             as off_epa_per_play,
        sum(success) / count(*)                         as success_rate,
        sum(iff(down in (1, 2), success, 0))
            / nullif(count_if(down in (1, 2)), 0)       as early_down_success_rate,
        count_if(pass = 1)                              as dropbacks,
        sum(iff(pass = 1, epa, 0))                      as pass_epa,
        sum(iff(pass = 1, epa, 0))
            / nullif(count_if(pass = 1), 0)             as pass_epa_per_dropback,
        count_if(rush = 1)                              as carries,
        sum(iff(rush = 1, epa, 0))                      as rush_epa,
        sum(iff(rush = 1, epa, 0))
            / nullif(count_if(rush = 1), 0)             as rush_epa_per_carry,
        count_if((pass = 1 and yards_gained >= 20) or (rush = 1 and yards_gained >= 10))
            / count(*)                                  as explosive_rate,
        avg(cpoe)                                       as cpoe,
        count_if(pass = 1) / count(*)                   as pass_rate,
        avg(pass - xpass)                               as proe,
        -- additive counts behind the rates above, so other grains can
        -- re-aggregate sum-over-sum (same contract as fact_team_game_situation)
        count_if(success = 1)                           as success_plays,
        count_if((pass = 1 and yards_gained >= 20)
              or (rush = 1 and yards_gained >= 10))     as explosive_plays,
        count_if(down in (1, 2))                        as early_down_plays,
        count_if(down in (1, 2) and success = 1)        as early_down_success_plays,
        sum(iff(xpass is not null, pass - xpass, null)) as pass_over_expected_sum,
        count_if(xpass is not null)                     as xpass_plays
    from epa_plays
    group by 1, 2

),

epa_by_team_game as (

    select
        g.game_id,
        iff(e.team = g.home_abbr_nflverse, g.home_team_id, g.away_team_id)
                                                        as team_id,
        e.* exclude (nflverse_game_id, team)
    from epa_offense e
    inner join {{ ref('bridge_game_ids') }} g
        on g.nflverse_game_id = e.nflverse_game_id

)

select
    -- ---------------------------------------------------------------
    -- keys
    -- ---------------------------------------------------------------
    {{ dbt_utils.generate_surrogate_key(['tg.game_id', 'tg.team_id']) }}   as team_game_key,
    tg.game_key,
    tg.game_id,
    tg.team_key,
    tg.team_id,
    tg.opponent_team_key,
    tg.opponent_team_id,
    {{ dbt_utils.generate_surrogate_key(['tg.game_date']) }}               as date_key,
    {{ dbt_utils.generate_surrogate_key(['tg.season', 'tg.week', 'tg.season_type']) }}
                                                                as season_week_key,

    -- ---------------------------------------------------------------
    -- degenerate dimensions / context
    -- ---------------------------------------------------------------
    tg.game_date,
    tg.season,
    tg.week,
    tg.season_type,
    tg.is_postseason,
    tg.is_home,
    tg.went_to_overtime,

    -- ---------------------------------------------------------------
    -- result. Ties are real in the NFL (rare, but they happen), so this is
    -- three flags rather than a single boolean.
    -- ---------------------------------------------------------------
    tg.points_scored,
    tg.points_allowed,
    tg.points_scored - tg.points_allowed                        as point_margin,
    (tg.points_scored > tg.points_allowed)                      as is_win,
    (tg.points_scored < tg.points_allowed)                      as is_loss,
    (tg.points_scored = tg.points_allowed)                      as is_tie,

    -- additive integer counters, so records aggregate with a plain sum
    iff(tg.points_scored > tg.points_allowed, 1, 0)             as win_count,
    iff(tg.points_scored < tg.points_allowed, 1, 0)             as loss_count,
    iff(tg.points_scored = tg.points_allowed, 1, 0)             as tie_count,

    -- scoring by period
    tg.points_q1,
    tg.points_q2,
    tg.points_q3,
    tg.points_q4,
    tg.points_ot,

    -- ---------------------------------------------------------------
    -- box score. NULL for the 4 team-game rows whose game has no team_stats.
    -- ---------------------------------------------------------------
    bs.first_downs,
    bs.first_downs_passing,
    bs.first_downs_rushing,
    bs.first_downs_penalty,

    bs.third_down_conversions,
    bs.third_down_attempts,
    bs.fourth_down_conversions,
    bs.fourth_down_attempts,
    bs.red_zone_scores,
    bs.red_zone_attempts,

    bs.total_drives,
    bs.total_offensive_plays,
    bs.possession_time_seconds,

    bs.total_yards,
    bs.yards_per_play,
    bs.net_passing_yards,
    bs.passing_completions,
    bs.passing_attempts,
    bs.yards_per_pass,
    bs.rushing_yards,
    bs.rushing_attempts,
    bs.yards_per_rush_attempt,

    bs.sacks_allowed,
    bs.sack_yards_lost,
    bs.turnovers,
    bs.fumbles_lost,
    bs.interceptions_thrown,
    bs.penalties,
    bs.penalty_yards,
    bs.defensive_touchdowns,

    -- flags whether the box score joined, so consumers can exclude the 4 gaps
    -- without needing to know which measure to null-check
    (bs.team_game_key is not null)                              as has_box_score,

    -- ---------------------------------------------------------------
    -- nflverse EPA block (see header). NULL on preseason rows -- nflverse
    -- publishes no preseason play-by-play. Rates come from this grain's own
    -- sums; re-aggregate from the counts and epa sums, never from the rates.
    -- ---------------------------------------------------------------
    ep.off_plays,
    ep.off_epa,
    ep.off_epa_per_play,
    ep.success_rate,
    ep.early_down_success_rate,
    ep.dropbacks,
    ep.pass_epa,
    ep.pass_epa_per_dropback,
    ep.carries,
    ep.rush_epa,
    ep.rush_epa_per_carry,
    ep.explosive_rate,
    ep.cpoe,
    ep.pass_rate,
    ep.proe,
    ep.success_plays,
    ep.explosive_plays,
    ep.early_down_plays,
    ep.early_down_success_plays,
    ep.pass_over_expected_sum,
    ep.xpass_plays,

    (ep.game_id is not null)                                    as has_nflverse

from team_games tg
left join box_score bs
    on  tg.game_id = bs.game_id
    and tg.team_id = bs.team_id
left join epa_by_team_game ep
    on  tg.game_id = ep.game_id
    and tg.team_id = ep.team_id
