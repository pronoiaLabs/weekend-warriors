{{
    config(
        materialized='incremental',
        unique_key='player_game_key',
        incremental_strategy='merge'
    )
}}

/*
    fact_player_game_offense -- passing, rushing and receiving.
    Grain: player x game. ~21,700 rows.

    Incremental (merge on player_game_key); see fact_play for the watermark
    pattern and its two traps (NUMBER(38,6), the two-condition filter). One
    phase-fact wrinkle, shared by all three and accepted: a load id none of
    whose rows pass this fact's phase filter never enters its watermark set,
    so the `not in` arm re-reads that load's rows on every run, filters them
    out again, and merges nothing. Idempotent and cheap -- every real weekly
    load has all three phases in practice -- but no-op runs show nonzero
    scanned rows.

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
*/

with stats as (

    select * from {{ ref('stg_nfl__player_stats') }}

    {% if is_incremental() %}
    -- Pick up rows from any load this table has not already fully absorbed.
    --
    -- Two conditions, both needed:
    --   >= max   catches a load that landed only partially on a previous run.
    --            Strict > would exclude the rest of that batch forever, since
    --            those rows are EQUAL to the watermark, not greater.
    --   not in   catches an out-of-order load. dlt stamps _dlt_load_id when the
    --            load package is created, not when it commits, so a resource
    --            that started earlier but committed later carries a LOWER id
    --            and would never exceed the max.
    --
    -- Both re-read rows that may already be present, which is free here because
    -- the merge on player_game_key is idempotent.
    where _dlt_load_id::number(38, 6) >= (
              select coalesce(max(dlt_load_id_numeric), 0) from {{ this }}
          )
       or _dlt_load_id::number(38, 6) not in (
              select distinct dlt_load_id_numeric from {{ this }}
          )
    {% endif %}

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

    -- Every column published as a measure below must appear in this filter.
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

    -- exact numeric watermark for the next incremental run. NOT float: a float
    -- cast loses precision on a 17-digit load id and breaks the comparison.
    o._dlt_load_id::number(38, 6)                       as dlt_load_id_numeric

from offense o
inner join games g
    on o.game_key = g.game_key
