{{
    config(
        materialized='incremental',
        unique_key='player_game_key',
        incremental_strategy='merge'
    )
}}

/*
    fact_player_game_defense -- tackles, pressure and coverage.
    Grain: player x game. ~42,300 rows, the largest of the three phase facts.

    Incremental (merge on player_game_key); see fact_play for the watermark
    pattern and its traps, and fact_player_game_offense for the phase-fact
    watermark wrinkle all three share.

    See fact_player_game_offense for the full explanation of the phase split and
    the deliberate cross-fact key overlap. Short version: measure sets are
    disjoint, keys can repeat across facts, so aggregate each fact independently
    and never UNION them.

    defensive_sacks is a coalesced dlt variant column and is FLOAT, not integer:
    a shared sack counts as 0.5. Do not cast it to int.

    Fumbles: recovered and returned-for-score sit here (defensive outcomes);
    fumbles committed/lost sit on the offense fact. Both of those columns are in
    the activity filter below -- they have to be, because they are published as
    measures here. Leaving them out dropped 1,022 player-games whose only
    defensive contribution was a fumble recovery, hiding 1,061 of 2,058
    recoveries and understating takeaways by 30%.
*/

with stats as (

    select * from {{ ref('stg_nfl__player_stats') }}

    {% if is_incremental() %}
    -- Pick up rows from any load this table has not already fully absorbed.
    -- Two conditions, both needed; see fact_play for the full rationale
    -- (>= max catches a partially-landed load; not in catches an
    -- out-of-order load id). Re-reads are free: the merge is idempotent.
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

defense as (

    -- Every column published as a measure by this model must appear here.
    -- fumbles_recovered / fumbles_touchdowns are easy to forget because they
    -- read as "fumble" rather than "defense", but they are defensive takeaways
    -- and appear on no other fact -- omitting them made those rows unreachable
    -- warehouse-wide.
    select *
    from stats
    where coalesce(
              total_tackles,
              solo_tackles,
              tackles_for_loss,
              defensive_sacks,
              qb_hits,
              passes_defended,
              defensive_interceptions,
              fumbles_recovered,
              fumbles_touchdowns
          ) is not null

)

select
    -- keys
    d.player_game_key,
    d.game_key,
    d.game_id,
    d.player_key,
    d.player_id,
    d.team_key,
    d.team_id,
    g.date_key,
    g.season_week_key,

    -- context
    g.season,
    g.week,
    g.season_type,
    g.is_postseason,

    -- ---------------------------------------------------------------
    -- tackling
    -- ---------------------------------------------------------------
    d.total_tackles,
    d.solo_tackles,
    d.tackles_for_loss,

    -- ---------------------------------------------------------------
    -- pass rush. FLOAT: half-sacks are real.
    -- ---------------------------------------------------------------
    d.defensive_sacks,
    d.qb_hits,

    -- ---------------------------------------------------------------
    -- coverage
    -- ---------------------------------------------------------------
    d.passes_defended,
    d.defensive_interceptions,
    d.interception_yards,
    d.interception_touchdowns,

    -- ---------------------------------------------------------------
    -- takeaways
    -- ---------------------------------------------------------------
    d.fumbles_recovered,
    d.fumbles_touchdowns,

    -- ---------------------------------------------------------------
    -- derived: total takeaways and total defensive scores, the two roll-ups
    -- most defensive questions reach for
    -- ---------------------------------------------------------------
    coalesce(d.defensive_interceptions, 0) + coalesce(d.fumbles_recovered, 0)
                                                        as takeaways,
    coalesce(d.interception_touchdowns, 0) + coalesce(d.fumbles_touchdowns, 0)
                                                        as defensive_touchdowns,

    -- assisted tackles are not published directly; total minus solo is the
    -- standard derivation. Guarded so a missing solo count cannot go negative.
    case
        when d.total_tackles is not null and d.solo_tackles is not null
             and d.total_tackles >= d.solo_tackles
        then d.total_tackles - d.solo_tackles
    end                                                 as assisted_tackles,

    -- exact numeric watermark for the next incremental run. NOT float: a float
    -- cast loses precision on a 17-digit load id and breaks the comparison.
    d._dlt_load_id::number(38, 6)                       as dlt_load_id_numeric

from defense d
inner join games g
    on d.game_key = g.game_key
