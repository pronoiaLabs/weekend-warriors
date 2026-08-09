{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__rankings -- one row per season per week per ranked team:
    the AP-style Top 25, weeks 2-16, ~375 rows per completed season.

    ONE POLL, UNNAMED: the API exposes a single poll with no identifier
    (66 first-place votes and 25 teams shape it like the AP poll). If the
    provider ever adds a second poll the rows would collide invisibly, which
    is why the rankings integrity test pins 25-ish rows per week.

    The endpoint returns only the LATEST published week per call; the weekly
    Monday cron accumulates the season, and 2024-2025 history was backfilled
    week by week. Week 1 does not exist (the first poll is week 2, i.e. the
    preseason poll); a 2024 rank tie produced one 26-row week.

    RECORD is a 'W-L' text pair, parsed here (tie-capable, see
    ncaaf_parse_record); TREND is text like '+1', '-1' or '-' and is parsed
    to a signed integer with NULL for the no-move dash.
*/

with source as (

    select * from {{ source('ncaaf_raw', 'rankings') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['season', 'week', 'team__id']) }}
                                                            as ranking_key,

        {{ dbt_utils.generate_surrogate_key(['team__id']) }}   as team_key,
        team__id                                            as team_id,
        season,
        week,

        rank                                                as poll_rank,
        first_place_votes,
        points                                              as poll_points,
        trend                                               as trend_text,
        try_cast(replace(trend, '+', '') as int)            as rank_change,
        record                                              as record_text,
        {{ ncaaf_parse_record('record', 'wins') }}          as record_wins,
        {{ ncaaf_parse_record('record', 'losses') }}        as record_losses

    from source

)

select * from renamed
