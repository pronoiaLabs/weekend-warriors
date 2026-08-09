{{
    config(
        materialized='table'
    )
}}

/*
    dim_ncaaf_game -- descriptive context per game. Grain: game, ~4,977
    rows, seasons 2024-2026.

    THE ONLY PLACE THE FULL NCAAF SLATE IS READABLE. NOT all played: the
    2026 season's games are scheduled rows with is_completed false and NULL
    scores (the source's fake 0-0 totals are nulled in prep). Facts filter
    to completed games, so "who does Ohio State play next" is answerable
    only here, which is exactly what sv_ncaaf_schedule anchors on.

    Carries the final score, like dim_wnba_game and unlike the NFL
    dimension, because this is the complete schedule and the scores are
    NULL-guarded upstream: a scheduled game cannot leak a fake shutout.

    Both spellings of the same instant: game_datetime (UTC) and
    game_datetime_et (US Eastern). The schedule semantic view exposes only
    the ET one.

    is_postseason means week 999 (bowls, CFP). One upstream mislabel exists
    (the Jan 2025 Gator Bowl carries week 1); tolerated, not patched.
*/

select
    g.game_key,
    g.game_id,

    g.game_datetime,
    g.game_datetime_et,
    g.game_date,
    d.date_key,
    g.season,
    g.week,
    g.is_postseason,

    g.game_status,
    g.game_state,
    g.is_completed,
    g.final_period,
    g.went_to_overtime,

    g.home_team_key,
    g.away_team_key,

    -- NULL-safe: written as an explicit CASE rather than hashing a NULL id,
    -- which would produce a real-looking key that resolves to no team.
    iff(g.winner_team_id is not null,
        {{ dbt_utils.generate_surrogate_key(['g.winner_team_id']) }},
        null)                                   as winner_team_key,

    g.home_team_score,
    g.away_team_score

from {{ ref('stg_ncaaf__games') }} g
left join {{ ref('dim_ncaaf_date') }} d
       on g.game_date = d.full_date
