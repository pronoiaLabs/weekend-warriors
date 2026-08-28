{{
    config(
        materialized='table'
    )
}}

/*
    fact_team_game_defense -- what THIS team's defense faced and did in ONE
    completed game. Grain: team x game, 1:1 with fact_team_game_offense on
    team_game_key: same rows, same keys, same context columns.

    fact_team_game_offense answers "what did this team's offense do": every
    box-score column there is the team's own yards, attempts, conversions and
    mistakes, and the game result rides with it because records aggregate from
    one row per team-game. This table is its mirror, in two blocks:

      * ALLOWED (opp_* columns). The opponent's offensive box score from the
        other row of the same game, re-read from this team's side.
        opp_total_yards is "yards allowed", opp_third_down_conversions is
        "third downs surrendered", opp_sacks_allowed is "sacks this defense
        got credit for on the team box", and so on. A self-join of the
        offense fact, not a recomputation from prep, so the two facts can
        never disagree about a number.

      * PRESSURE / COVERAGE. fact_player_game_defense rolled up to the team.
        Tackles, tackles for loss, sacks recorded, QB hits, passes defended,
        interceptions and fumble recoveries have no team-level source: the
        player box score is the only place the provider publishes them.

      * EPA ALLOWED (the retired fact_team_game_epa's defense half, folded
        in). A team's defensive EPA line IS its opponent's offensive one --
        the retired fact built def_* by re-reading the same scrimmage plays
        from the defending side, and the mirrors test held them equal -- so
        the def_* columns here read the opponent row's EPA block, the same
        self-join as the opp_* block and with the same cannot-disagree
        property. NULL on preseason rows (nflverse publishes no preseason
        play-by-play), flagged by has_nflverse; rates come from the offense
        grain's sums and cannot be re-aggregated.

    The self-join is safe because assert_fact_team_game_offense_is_mirrored
    guarantees exactly two rows per game with two distinct teams, so each row
    finds exactly one opponent row and the join cannot fan out.

    FIVE TRAPS, each measured across the 2,044 team-games where both sides
    have a box score (Aug 2026):

      1. sacks_allowed on the offense fact is NULL on 217 rows that otherwise
         have a box score, and 0 on only 42. League totals (4,931 allowed on
         the team box vs 4,917 recorded by players) show that NULL means
         "none", so opp_sacks_allowed coalesces to 0 whenever the opponent's
         box score exists and stays NULL only when it does not.

      2. fumbles_recovered from the player stats counts a team's recoveries
         of ITS OWN fumbles too, so it is not a takeaway: it disagrees with
         the opponent's fumbles_lost on 841 rows. takeaways here is the
         opponent's turnovers, which is authoritative. The per-player
         takeaways column on fact_player_game_defense inherits the same
         inflation; do not sum it for a team.

      3. interceptions_recorded (player rollup) equals opp_interceptions_thrown
         on every row. sacks_recorded agrees with opp_sacks_allowed only
         within 1.0, on 18 rows (half-sack FLOATs and provider attribution).
         Both are asserted in assert_defense_pressure_reconciles_to_opponent_offense.

      4. The provider's team-box defensive_touchdowns and the player rollup
         (interception return TDs + fumble return TDs) disagree on 155 rows.
         Neither is demonstrably right, so both are exposed under explicit
         names and neither is tested against the other.

      5. No per-game rates. A rate averaged across games is wrong (a 1-for-2
         third-down game would weigh as much as a 6-for-12 one). Compute rates
         as sum / sum wherever they are consumed, from the counters here.

    Coverage: has_opp_box_score is false on the 4 rows whose opponent has no
    team_stats row (every opp_* measure NULL there), and has_player_defense is
    false on the same 4 rows: the two 2023 preseason week 4 games (ids 1393434
    and 1393440) have no player stats either. The flags are carried separately
    because they come from different endpoints; a future gap in one source
    should show on its own flag, not hide behind the other.
*/

with offense as (

    select * from {{ ref('fact_team_game_offense') }}

),

-- ---------------------------------------------------------------------------
-- Player defensive stats rolled up to the team. fact_player_game_defense is
-- incremental; this aggregate is rebuilt in full each run (a few thousand
-- groups, cheap). sum() over all-NULL columns yields NULL, and that is kept:
-- a NULL here means no player was credited, not zero.
-- ---------------------------------------------------------------------------
player_defense as (

    select
        game_key,
        team_key,
        sum(total_tackles)                  as total_tackles,
        sum(solo_tackles)                   as solo_tackles,
        sum(tackles_for_loss)               as tackles_for_loss,
        sum(defensive_sacks)                as sacks_recorded,        -- FLOAT, half-sacks
        sum(qb_hits)                        as qb_hits,
        sum(passes_defended)                as passes_defended,
        sum(defensive_interceptions)        as interceptions_recorded,
        sum(interception_yards)             as interception_yards,
        sum(interception_touchdowns)        as interception_touchdowns,
        sum(fumbles_recovered)              as fumbles_recovered,     -- includes OWN recoveries, see header
        sum(fumbles_touchdowns)             as fumbles_touchdowns,
        count(*)                            as defenders_with_stats
    from {{ ref('fact_player_game_defense') }}
    group by game_key, team_key

)

select
    -- ---------------------------------------------------------------
    -- keys. Identical to the offense row, so the two facts join 1:1.
    -- ---------------------------------------------------------------
    t.team_game_key,
    t.game_key,
    t.game_id,
    t.team_key,
    t.team_id,
    t.opponent_team_key,
    t.opponent_team_id,
    t.date_key,
    t.season_week_key,

    -- ---------------------------------------------------------------
    -- context
    -- ---------------------------------------------------------------
    t.game_date,
    t.season,
    t.week,
    t.season_type,
    t.is_postseason,
    t.is_home,

    -- the defensive half of the result. The full result stays on offense.
    t.points_allowed,

    -- ---------------------------------------------------------------
    -- ALLOWED: the opponent's offensive box score. NULL where the
    -- opponent has no team_stats row (has_opp_box_score = false).
    -- ---------------------------------------------------------------
    o.first_downs                                               as opp_first_downs,
    o.first_downs_passing                                       as opp_first_downs_passing,
    o.first_downs_rushing                                       as opp_first_downs_rushing,
    o.first_downs_penalty                                       as opp_first_downs_penalty,

    o.third_down_conversions                                    as opp_third_down_conversions,
    o.third_down_attempts                                       as opp_third_down_attempts,
    o.fourth_down_conversions                                   as opp_fourth_down_conversions,
    o.fourth_down_attempts                                      as opp_fourth_down_attempts,
    o.red_zone_scores                                           as opp_red_zone_scores,
    o.red_zone_attempts                                         as opp_red_zone_attempts,

    o.total_drives                                              as opp_total_drives,
    o.total_offensive_plays                                     as opp_total_offensive_plays,
    o.possession_time_seconds                                   as opp_possession_time_seconds,

    o.total_yards                                               as opp_total_yards,
    o.yards_per_play                                            as opp_yards_per_play,
    o.net_passing_yards                                         as opp_net_passing_yards,
    o.passing_completions                                       as opp_passing_completions,
    o.passing_attempts                                          as opp_passing_attempts,
    o.yards_per_pass                                            as opp_yards_per_pass,
    o.rushing_yards                                             as opp_rushing_yards,
    o.rushing_attempts                                          as opp_rushing_attempts,
    o.yards_per_rush_attempt                                    as opp_yards_per_rush_attempt,

    -- trap 1: NULL on a present box score means zero sacks
    iff(o.has_box_score, coalesce(o.sacks_allowed, 0), null)   as opp_sacks_allowed,
    o.sack_yards_lost                                           as opp_sack_yards_lost,
    o.turnovers                                                 as opp_turnovers,
    o.fumbles_lost                                              as opp_fumbles_lost,
    o.interceptions_thrown                                      as opp_interceptions_thrown,
    o.penalties                                                 as opp_penalties,
    o.penalty_yards                                             as opp_penalty_yards,

    coalesce(o.has_box_score, false)                            as has_opp_box_score,

    -- trap 2: takeaways are the opponent's turnovers, not fumbles_recovered
    o.turnovers                                                 as takeaways,

    -- ---------------------------------------------------------------
    -- PRESSURE / COVERAGE: fact_player_game_defense rolled up.
    -- ---------------------------------------------------------------
    d.total_tackles,
    d.solo_tackles,
    d.tackles_for_loss,
    d.sacks_recorded,
    d.qb_hits,
    d.passes_defended,
    d.interceptions_recorded,
    d.interception_yards,
    d.interception_touchdowns,
    d.fumbles_recovered,
    d.fumbles_touchdowns,
    d.defenders_with_stats,
    (d.game_key is not null)                                    as has_player_defense,

    -- ---------------------------------------------------------------
    -- EPA ALLOWED: the opponent row's nflverse EPA block, read from this
    -- team's side (see header). NULL on preseason rows.
    -- ---------------------------------------------------------------
    o.off_plays                                                 as def_plays,
    o.off_epa                                                   as def_epa,
    o.off_epa_per_play                                          as def_epa_per_play,
    o.success_rate                                              as success_rate_allowed,
    o.dropbacks                                                 as def_dropbacks_faced,
    o.pass_epa_per_dropback                                     as def_pass_epa_per_dropback,
    o.carries                                                   as def_carries_faced,
    o.rush_epa_per_carry                                        as def_rush_epa_per_carry,
    o.explosive_rate                                            as def_explosive_rate_allowed,

    coalesce(o.has_nflverse, false)                             as has_nflverse,

    -- ---------------------------------------------------------------
    -- trap 4: two defensive touchdown readings, deliberately both
    -- ---------------------------------------------------------------
    t.defensive_touchdowns                                      as defensive_touchdowns_team_box,
    iff(
        d.game_key is not null,
        coalesce(d.interception_touchdowns, 0) + coalesce(d.fumbles_touchdowns, 0),
        null
    )                                                           as defensive_touchdowns_player_rollup

from offense t
left join offense o
    on  t.game_key = o.game_key
    and t.opponent_team_key = o.team_key
left join player_defense d
    on  t.game_key = d.game_key
    and t.team_key = d.team_key
