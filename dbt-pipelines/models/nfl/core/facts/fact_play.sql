{{
    config(
        materialized='incremental',
        unique_key='play_key',
        incremental_strategy='merge',
        cluster_by=['season', 'week']
    )
}}

/*
    fact_play -- play-by-play. Grain: play. 179,402 rows.

    The only incremental model in the project. Everything else is small enough to
    rebuild; this one is 33 MB in the source and grows every week, so it merges
    on new dlt loads instead.

    Incremental logic: dlt writes an epoch-seconds value as _dlt_load_id on every
    row, so "newer than anything I already have" is a numeric comparison. The
    merge on play_key means a re-loaded play updates in place rather than
    duplicating -- important because dlt can replay a load.

    THE WATERMARK MUST NOT BE FLOAT. A load id like 1785603883.6409146 needs ~17
    significant digits and a 64-bit float carries ~15-16, so casting to FLOAT
    rounds it. The rounded stored value then compares as LESS than the original
    text, making `_dlt_load_id::float > max(watermark)` true for the rows it had
    already loaded -- 48,158 rows reprocessed on every no-op run. Row counts
    survived only because the merge updated in place; had the rounding gone the
    other way it would have SKIPPED rows silently. NUMBER(38,6) is exact.

    THE COMPARISON IS ALSO NOT A SIMPLE `>`. See the incremental block below --
    strict greater-than permanently skips both partially-landed loads and
    out-of-order load ids.

    Clustered on (season, week) since essentially every query filters by them.

    Two source characteristics carried through deliberately:
      * team_key is NULLABLE -- 126 plays are neutral events (kickoffs and the
        like) with no possessing team. The dimension join must tolerate it.
      * 18 games have no plays, so this fact does NOT cover all 1,002 games.
        Do not use it as a game spine.

    play_description holds the natural-language text and is the obvious candidate
    for a Cortex Search service later ("find plays where X happened").
*/

with plays as (

    select * from {{ ref('stg_nfl__plays') }}

    {% if is_incremental() %}
    -- Pick up rows from any load this table has not already fully absorbed.
    --
    -- Two conditions, both needed:
    --   >= max   catches a load that landed only partially on a previous run.
    --            Strict > would exclude the rest of that batch forever, since
    --            those rows are EQUAL to the watermark, not greater.
    --   not in   catches an out-of-order load. dlt stamps _dlt_load_id when the
    --            load package is created, not when it commits, and this source
    --            writes three load ids per run spread over ~90 seconds. A
    --            resource that started earlier but committed later carries a
    --            LOWER id and would never exceed the max.
    --
    -- Both re-read rows that may already be present, which is free here because
    -- the merge on play_key is idempotent.
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
        is_postseason,
        home_team_key,
        away_team_key
    from {{ ref('dim_game') }}

)

select
    -- ---------------------------------------------------------------
    -- keys
    -- ---------------------------------------------------------------
    p.play_key,
    p.play_id,
    p.game_key,
    p.game_id,

    -- nullable: neutral-event plays have no possessing team
    p.team_key,
    p.team_id,

    p.play_type_key,
    g.date_key,
    g.season_week_key,

    -- ---------------------------------------------------------------
    -- context
    -- ---------------------------------------------------------------
    g.season,
    g.week,
    g.season_type,
    g.is_postseason,

    -- which side had the ball, useful without joining back to the game
    case
        when p.team_key = g.home_team_key then true
        when p.team_key = g.away_team_key then false
    end                                             as is_home_possession,

    -- ---------------------------------------------------------------
    -- situation
    -- ---------------------------------------------------------------
    p.period,
    p.clock_display,
    p.clock_seconds_remaining,
    p.start_down,
    p.start_distance,
    p.start_yard_line,
    p.start_yards_to_endzone,

    p.end_down,
    p.end_distance,
    p.end_yard_line,
    p.end_yards_to_endzone,
    p.end_down_distance_text,
    p.end_possession_text,

    p.is_third_down,
    p.is_fourth_down,
    p.is_red_zone,

    -- ---------------------------------------------------------------
    -- outcome
    -- ---------------------------------------------------------------
    p.yards_gained,
    p.is_scoring_play,
    p.home_score_after_play,
    p.away_score_after_play,
    p.home_win_probability,

    -- derived: did this play gain enough for a first down.
    --
    -- The down guard is load-bearing. Kickoffs and clock events carry
    -- start_down = 0 and start_distance = 0, so a guard that only checks for
    -- NULLs lets `0 >= 0` through and flags them as first downs -- 1,612 of
    -- them, including every "End of Game" play in the table. Requiring a live
    -- down (1-4) and a real distance to gain restricts this to scrimmage plays.
    --
    -- NULL rather than false when the situation is unknown, so an unmeasurable
    -- play is not silently counted as a failed conversion.
    case
        when p.start_down between 1 and 4
         and p.start_distance > 0
         and p.yards_gained is not null
        then p.yards_gained >= p.start_distance
    end                                             as achieved_first_down,

    -- ---------------------------------------------------------------
    -- description (Cortex Search candidate)
    -- ---------------------------------------------------------------
    p.play_description,
    p.play_description_short,

    p.play_wallclock,

    -- exact numeric watermark for the next incremental run. NOT float: a float
    -- cast loses precision on a 17-digit load id and breaks the comparison.
    p._dlt_load_id::number(38, 6)                   as dlt_load_id_numeric

from plays p
inner join games g
    on p.game_key = g.game_key
