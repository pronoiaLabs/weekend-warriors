{{ config(materialized='table') }}

/*
    fact_player_game_offense -- passing, rushing and receiving, all vendors.
    Grain: player x game. ~21,700 rows. BallDontLie is the anchor: every row
    exists because the BDL box score has one, and the nflverse and Sleeper
    blocks ride along where the bridges find the same player-week.

    One of three phase facts split out of the 116-column STATS source. The split
    exists because a single wide fact would be ~100 measures, almost all NULL for
    any given row -- a punter's row carries nothing in the passing columns.

    ABOUT THE OVERLAP: 4,613 player-games show activity in more than one phase,
    so those rows appear in more than one phase fact. That is correct, because
    the measure sets are disjoint -- no measure is duplicated, only the key. The
    consequence is that row counts across the three phase facts do NOT sum to
    67,191, and a UNION of them would double-count keys. Aggregate each fact
    independently.

    ALSO: 386 STATS rows show no activity in any phase and land in none of the
    three facts. tests/assert_player_game_phase_coverage.sql monitors that count
    so it cannot drift silently.

    Filter condition: any passing, rushing or receiving involvement. Uses
    coalesce over the volume columns rather than a position lookup, because
    position is 'Unknown' for 801 of the players who actually appear in box
    scores -- filtering on position would drop real production.

    Fumbles: lost/committed sit here (they are offensive events);
    fumbles_recovered and fumbles_touchdowns sit on the defense fact. Both
    published fumble columns are in the activity filter below -- they must be,
    or a player whose only recorded action was a fumble is dropped and the
    measure becomes unreachable. Note the consequence: a special-teamer who
    fumbled on a return appears in this fact with no passing/rushing/receiving
    volume. That is the correct trade -- the alternative loses the fumble.

    FANTASY POINTS (fanduel_points, draftkings_points). The scoring math is
    NOT here: it is the NFL_FANDUEL_POINTS and NFL_DRAFTKINGS_POINTS SQL UDFs
    in macros/nfl/nfl_fantasy_udfs.sql, generated from one coefficient table
    and created by dbt_project.yml's on-run-start so they exist before this
    fact builds, in the schema CORE resolves to. This model only passes the
    same thirteen measures to each. The books differ only in receptions
    (FanDuel 0.5, DraftKings 1.0) and fumbles lost (-2, -1).
    Three of the inputs need a word. fumbles_touchdowns, kick_return_touchdowns and
    punt_return_touchdowns sit on the same STATS row but are PUBLISHED by the
    defense and special facts; they are read here inside the expression only,
    never republished, so the one-measure-one-fact invariant that
    assert_phase_fact_measures_reconcile.sql guards still holds. Two-point
    conversions exist nowhere in the box score; fact_two_point_conversion
    parses them out of play-by-play text and they join on player_game_key.
    Not counted, by construction: a player whose only action was a return TD
    or a fumble-recovery TD with no passing/rushing/receiving volume is not in
    this fact (the activity filter is unchanged); two-point conversions in the
    23 completed games that have no play-by-play; kicker scoring, which needs
    field-goal distance the source does not carry.

    VENDOR BLOCKS. The row resolves to the other vendors through the bridges:
    player_key -> bridge_player_ids -> gsis_id / pfr_id / sleeper_player_id,
    game_key -> bridge_game_ids -> nflverse_game_id (which absorbs the
    postseason week mapping: BDL numbers the playoffs 1, 2, 3, 5 where
    nflverse continues at 19-22). nflverse player stats and snap counts join
    on that game id; Sleeper has no team in its game id, so its week stats
    join on season + week (postseason week + 18 = nflverse_week, the same
    resolution the retired fact_sleeper_player_week used). NULL means no
    match, never 0; has_nflverse / has_sleeper flag the joins. Measured Aug
    2026, excluding preseason (nflverse publishes none, by construction):
    99.3% of regular-season and 99.2% of postseason rows carry the nflverse
    block; Sleeper lands 83.8% / 87.3%.
*/

with stats as (

    select * from {{ ref('stg_nfl__player_stats') }}

),

games as (

    select
        game_key,
        date_key,
        season_week_key,
        season,
        week,
        season_type,
        is_postseason
    from {{ ref('dim_game') }}

),

offense as (

    -- Every column published as a BDL measure below must appear in this filter.
    select *
    from stats
    where coalesce(
              passing_attempts,
              passing_completions,
              rushing_attempts,
              rushing_yards,
              receiving_targets,
              receptions,
              fumbles,
              fumbles_lost
          ) is not null

),

-- successful, resolved two-point conversions per player-game. Passer and
-- receiver are separate rows upstream, so the split into thrown vs converted
-- falls out of the role.
two_point as (

    select
        player_game_key,
        sum(iff(role in ('rush', 'receive'), 1, 0))     as two_point_conversions,
        sum(iff(role = 'pass', 1, 0))                   as two_point_conversions_thrown
    from {{ ref('fact_two_point_conversion') }}
    where is_success
      and player_key is not null
    group by player_game_key

),

-- One row per player_key. The bridge's grain is gsis_id and BallDontLie holds
-- a few duplicate player ids mapped to one gsis row, so the qualify keeps the
-- join from fanning out if a duplicate ever maps the other way.
bridge as (

    select player_key, gsis_id, pfr_id, sleeper_player_id
    from {{ ref('bridge_player_ids') }}
    where player_key is not null
    qualify row_number() over (partition by player_key order by gsis_id) = 1

),

game_bridge as (

    select game_key, nflverse_game_id, nflverse_week, season, week,
           season_type, is_postseason
    from {{ ref('bridge_game_ids') }}

),

nflverse as (

    select * from {{ ref('stg_nfl__nflverse_player_stats') }}

),

snaps as (

    select pfr_player_id, nflverse_game_id, offense_snaps, offense_pct
    from {{ ref('stg_nfl__nflverse_snap_counts') }}

),

sleeper as (

    -- No is_team_defense filter: the DEF team rows carry the club abbreviation
    -- as their id and can never match the bridge's numeric sleeper ids, while
    -- prep's length-based flag also catches real veterans with short ids
    -- (id 96, 167, ...) whose weeks belong here.
    select * from {{ ref('stg_nfl__sleeper_stats') }}

)

select
    -- ---------------------------------------------------------------
    -- keys
    -- ---------------------------------------------------------------
    o.player_game_key,
    o.game_key,
    o.game_id,
    o.player_key,
    o.player_id,
    o.team_key,
    o.team_id,
    g.date_key,
    g.season_week_key,

    -- context, denormalised for convenient filtering
    g.season,
    g.week,
    g.season_type,
    g.is_postseason,

    -- ---------------------------------------------------------------
    -- passing
    -- ---------------------------------------------------------------
    o.passing_attempts,
    o.passing_completions,
    o.passing_yards,
    o.yards_per_pass_attempt,
    o.passing_touchdowns,
    o.passing_interceptions,
    o.times_sacked,
    o.sack_yards_lost,
    o.qb_rating,
    o.qbr,

    -- ---------------------------------------------------------------
    -- rushing
    -- ---------------------------------------------------------------
    o.rushing_attempts,
    o.rushing_yards,
    o.yards_per_rush_attempt,
    o.rushing_touchdowns,
    o.long_rushing,

    -- ---------------------------------------------------------------
    -- receiving
    -- ---------------------------------------------------------------
    o.receiving_targets,
    o.receptions,
    o.receiving_yards,
    o.yards_per_reception,
    o.receiving_touchdowns,
    o.long_reception,

    -- ---------------------------------------------------------------
    -- ball security
    -- ---------------------------------------------------------------
    o.fumbles,
    o.fumbles_lost,

    -- ---------------------------------------------------------------
    -- derived: total scrimmage production, the measure most "best skill
    -- player" questions actually want. coalesce to 0 so a pure rusher is not
    -- nulled out by having no receiving line.
    -- ---------------------------------------------------------------
    coalesce(o.rushing_yards, 0) + coalesce(o.receiving_yards, 0)
                                                        as scrimmage_yards,
    coalesce(o.rushing_touchdowns, 0) + coalesce(o.receiving_touchdowns, 0)
                                                        as scrimmage_touchdowns,
    coalesce(o.rushing_attempts, 0) + coalesce(o.receptions, 0)
                                                        as touches,

    -- phase participation flags, so consumers can isolate a discipline without
    -- null-checking a measure
    (o.passing_attempts  is not null)                   as has_passing,
    (o.rushing_attempts  is not null)                   as has_rushing,
    (o.receiving_targets is not null)                   as has_receiving,

    -- ---------------------------------------------------------------
    -- two-point conversions, from play-by-play (see header)
    -- ---------------------------------------------------------------
    coalesce(tp.two_point_conversions, 0)               as two_point_conversions,
    coalesce(tp.two_point_conversions_thrown, 0)        as two_point_conversions_thrown,

    -- ---------------------------------------------------------------
    -- fantasy points, one column per book. The scoring math is the
    -- NFL_<BOOK>_POINTS UDFs (macros/nfl/nfl_fantasy_udfs.sql), created by
    -- on-run-start; both take the same thirteen inputs. The three inputs
    -- read from other phases' measures are explained in the header.
    -- ---------------------------------------------------------------
    {{ nfl_fantasy_points_fqn('fanduel') }}(
        o.receptions,
        o.receiving_yards,
        o.receiving_touchdowns,
        o.rushing_yards,
        o.rushing_touchdowns,
        o.passing_yards,
        o.passing_touchdowns,
        o.passing_interceptions,
        o.fumbles_lost,
        o.fumbles_touchdowns,
        coalesce(o.kick_return_touchdowns, 0) + coalesce(o.punt_return_touchdowns, 0),
        tp.two_point_conversions,
        tp.two_point_conversions_thrown
    )                                                   as fanduel_points,
    {{ nfl_fantasy_points_fqn('draftkings') }}(
        o.receptions,
        o.receiving_yards,
        o.receiving_touchdowns,
        o.rushing_yards,
        o.rushing_touchdowns,
        o.passing_yards,
        o.passing_touchdowns,
        o.passing_interceptions,
        o.fumbles_lost,
        o.fumbles_touchdowns,
        coalesce(o.kick_return_touchdowns, 0) + coalesce(o.punt_return_touchdowns, 0),
        tp.two_point_conversions,
        tp.two_point_conversions_thrown
    )                                                   as draftkings_points,

    -- ---------------------------------------------------------------
    -- nflverse: usage, the headline gain -- what the box score cannot say
    -- about how the offense flows through a player
    -- ---------------------------------------------------------------
    nv.target_share,
    nv.air_yards_share,
    nv.wopr,
    nv.racr,
    nv.pacr,
    nv.passing_air_yards,
    nv.receiving_air_yards,
    nv.passing_yards_after_catch,
    nv.receiving_yards_after_catch,

    -- nflverse: efficiency
    nv.passing_epa,
    nv.rushing_epa,
    nv.receiving_epa,
    nv.passing_cpoe,

    -- nflverse: detail -- first downs, explosive-play buckets, sack fumbles,
    -- and nflverse's own fantasy scorings (distinct from the UDF columns
    -- above: different scoring systems, kept under the vendor's names)
    nv.passing_first_downs,
    nv.rushing_first_downs,
    nv.receiving_first_downs,
    nv.passing_10,
    nv.passing_16,
    nv.passing_20,
    nv.passing_40,
    nv.rushing_10,
    nv.rushing_12,
    nv.rushing_20,
    nv.rushing_40,
    nv.receiving_10,
    nv.receiving_16,
    nv.receiving_20,
    nv.receiving_40,
    nv.sack_fumbles,
    nv.sack_fumbles_lost,
    nv.fantasy_points,
    nv.fantasy_points_ppr,

    -- nflverse: snaps, via the pfr crosswalk on the bridge
    sn.offense_snaps,
    sn.offense_pct,

    (nv.gsis_id is not null)                            as has_nflverse,

    -- ---------------------------------------------------------------
    -- Sleeper: the three fantasy scorings of the actual week and the
    -- positional rank per scoring
    -- ---------------------------------------------------------------
    sl.pts_std,
    sl.pts_half_ppr,
    sl.pts_ppr,
    sl.pos_rank_std,
    sl.pos_rank_half_ppr,
    sl.pos_rank_ppr,

    -- Sleeper: snap share with the team denominator built in
    sl.off_snp,
    sl.tm_off_snp,
    sl.off_snp / nullif(sl.tm_off_snp, 0)               as off_snap_share,

    -- Sleeper: detail BDL lacks
    sl.rec_drop,
    sl.rec_air_yd,
    sl.rec_fd,
    sl.rush_fd,
    sl.pass_rtg,

    (sl.sleeper_player_id is not null)                  as has_sleeper

from offense o
inner join games g
    on o.game_key = g.game_key
left join two_point tp
    on o.player_game_key = tp.player_game_key
left join bridge b
    on b.player_key = o.player_key
left join game_bridge gb
    on gb.game_key = o.game_key
left join nflverse nv
    on  nv.gsis_id = b.gsis_id
    and nv.nflverse_game_id = gb.nflverse_game_id
left join snaps sn
    on  sn.pfr_player_id = b.pfr_id
    and sn.nflverse_game_id = gb.nflverse_game_id
left join sleeper sl
    on  sl.sleeper_player_id = b.sleeper_player_id
    and sl.season = gb.season
    and case sl.season_type
            when 'regular' then gb.season_type = 2 and sl.week = gb.week
            when 'post'    then gb.is_postseason and sl.week + 18 = gb.nflverse_week
            when 'pre'     then gb.season_type = 1 and sl.week = gb.week
        end
