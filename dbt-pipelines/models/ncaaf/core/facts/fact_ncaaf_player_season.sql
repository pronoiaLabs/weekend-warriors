{{
    config(
        materialized='table'
    )
}}

/*
    fact_ncaaf_player_season -- one row per player per season, ~17,198 rows
    (2024-2025; 2026 appears once the API publishes in-season rollups).

    Loaded, not modelled, because the source's rate columns (yards per game,
    ratings, averages) carry denominators the game grain cannot always
    reproduce. team_key is the STAT-LINE team (see the prep header), the
    season-accurate answer across transfers.
*/

select
    player_season_key,
    player_key,
    player_id,
    team_key,
    team_id,
    season,

    passing_completions,
    passing_attempts,
    passing_yards,
    passing_yards_per_game,
    passing_touchdowns,
    passing_interceptions,
    passing_rating,

    rushing_attempts,
    rushing_yards,
    rushing_yards_per_game,
    rushing_avg,
    rushing_touchdowns,

    receptions,
    receiving_yards,
    receiving_yards_per_game,
    receiving_avg,
    receiving_touchdowns,

    total_tackles,
    solo_tackles,
    sacks,
    interceptions,
    passes_defended

from {{ ref('stg_ncaaf__player_season_stats') }}
