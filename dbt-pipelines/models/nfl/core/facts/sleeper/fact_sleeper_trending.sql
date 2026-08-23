{{ config(materialized='table') }}

/*
    fact_sleeper_trending -- the add/drop leaderboard, one row per appearance.
    Grain: fetched_at x direction x player.

    Appended every six hours: move_count is how many Sleeper leagues added or
    dropped the player in the trailing 24 hours, board_rank his position on
    that fetch's top-100. The crowd reacting to news hours before an official
    designation, which is exactly when a pre-kickoff feature wants it.
*/

select
    {{ dbt_utils.generate_surrogate_key(['t.fetched_at', 't.direction', 't.sleeper_player_id']) }}
                                                        as trending_key,
    p.player_key,
    p.gsis_id,
    t.sleeper_player_id,
    t.fetched_at,
    t.fetched_at::date                                  as trend_date,
    t.direction,
    t.move_count,
    t.board_rank,
    t.lookback_hours,
    t.state_season,
    t.state_week,
    t.state_season_type,
    t.loaded_at
from {{ ref('stg_nfl__sleeper_trending') }} t
left join {{ ref('bridge_player_ids') }} p
    on p.sleeper_player_id = t.sleeper_player_id
