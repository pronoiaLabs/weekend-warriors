{{
    config(
        materialized='table'
    )
}}

/*
    fact_ncaaf_player_game -- one row per player per COMPLETED game,
    ~173,688 rows. The box score at player grain.

    The join to games adds what the stat payload cannot say: whether this
    player's team was home or away, and the opponent. The stat line's own
    team_key is season-accurate (transfers included) and is the one to use;
    dim_ncaaf_player.current_team_key is not.

    COVERAGE CAVEAT inherited from the source: passing, rushing, receiving
    and defense only. No fumbles, no kicking, no punting, no returns.
*/

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
    ps.passes_defended

from {{ ref('stg_ncaaf__player_stats') }} ps
join {{ ref('stg_ncaaf__games') }} g
  on ps.game_id = g.game_id
