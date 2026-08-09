{{
    config(
        materialized='table'
    )
}}

/*
    fact_ncaaf_ranking -- the AP-style Top 25, one row per season per week
    per ranked team, weeks 2-16 (~375 rows per completed season).

    is_latest_poll marks the most recent published week PER SEASON, so
    "the current top 25" is a flag filter rather than a subquery, and the
    semantic view's latest-week rule has a column to bind to. For a
    completed season the flag marks the final poll.

    One unnamed poll (AP-shaped); a 2024 rank tie produced one 26-row week,
    which is why rank is not unique per week in the tests.
*/

select
    ranking_key,
    team_key,
    team_id,
    season,
    week,

    poll_rank,
    first_place_votes,
    poll_points,
    trend_text,
    rank_change,
    record_text,
    record_wins,
    record_losses,

    (week = max(week) over (partition by season)) as is_latest_poll

from {{ ref('stg_ncaaf__rankings') }}
