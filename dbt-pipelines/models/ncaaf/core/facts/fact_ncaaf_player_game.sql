{{
    config(
        materialized='incremental',
        unique_key='player_game_key',
        incremental_strategy='merge',
        cluster_by=['season', 'week']
    )
}}

/*
    fact_ncaaf_player_game -- one row per player per COMPLETED game,
    ~173,688 rows. The box score at player grain.

    Incremental (merge on player_game_key); see fact_play for the watermark
    pattern and its two traps (NUMBER(38,6), the two-condition filter).
    Clustered on (season, week) like fact_play: comparable size, same access
    pattern. A stats row whose game has not landed in stg_ncaaf__games yet is
    dropped by the inner join with its load id already watermarked; it is
    recovered by a later re-load of that game or a full refresh (the same
    exposure fact_play accepts).

    The join to games adds what the stat payload cannot say: whether this
    player's team was home or away, and the opponent. The stat line's own
    team_key is season-accurate (transfers included) and is the one to use;
    dim_ncaaf_player.current_team_key is not.

    COVERAGE CAVEAT inherited from the source: passing, rushing, receiving
    and defense only. No fumbles, no kicking, no punting, no returns.
*/

with player_stats as (

    select * from {{ ref('stg_ncaaf__player_stats') }}

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

    select * from {{ ref('stg_ncaaf__games') }}

)

select
    ps.player_game_key,
    ps.player_key,
    ps.player_id,
    ps.team_key,
    ps.team_id,
    ps.game_key,
    ps.game_id,
    ps.season,
    ps.week,
    ps.game_date,
    g.is_postseason,
    (ps.team_id = g.home_team_id)               as is_home,
    iff(ps.team_id = g.home_team_id,
        g.away_team_key, g.home_team_key)       as opponent_team_key,

    ps.passing_completions,
    ps.passing_attempts,
    ps.passing_yards,
    ps.passing_touchdowns,
    ps.passing_interceptions,
    ps.passing_qbr,
    ps.passing_rating,

    ps.rushing_attempts,
    ps.rushing_yards,
    ps.rushing_touchdowns,
    ps.rushing_long,

    ps.receptions,
    ps.receiving_yards,
    ps.receiving_touchdowns,
    ps.receiving_long,

    ps.total_tackles,
    ps.solo_tackles,
    ps.tackles_for_loss,
    ps.sacks,
    ps.interceptions,
    ps.passes_defended,

    -- exact numeric watermark for the next incremental run. NOT float: a float
    -- cast loses precision on a 17-digit load id and breaks the comparison.
    ps._dlt_load_id::number(38, 6)              as dlt_load_id_numeric

from player_stats ps
join games g
  on ps.game_id = g.game_id
