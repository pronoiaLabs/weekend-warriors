{{
    config(
        materialized='table'
    )
}}

/*
    fact_ncaaf_team_season -- one row per team per season, ~270 rows.

    FBS ONLY: the source publishes season rollups for about 135 FBS
    programs and nothing below, so this fact cannot answer season-level
    questions about FCS teams (their game grain still can). The semantic
    view's AI rules carry the same caveat.

    Kept for the opponent totals (opp_passing_yards, opp_rushing_yards)
    that exist nowhere else, and the rate columns whose denominators the
    game grain cannot always reproduce.
*/

select
    team_season_key,
    team_key,
    team_id,
    season,

    passing_yards,
    passing_yards_per_game,
    passing_touchdowns,
    passing_interceptions,
    passing_qb_rating,

    rushing_yards,
    rushing_yards_per_game,
    rushing_touchdowns,

    receiving_yards,
    receiving_touchdowns,

    opp_passing_yards,
    opp_rushing_yards

from {{ ref('stg_ncaaf__team_season_stats') }}
