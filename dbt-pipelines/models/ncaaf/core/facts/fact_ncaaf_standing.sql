{{
    config(
        materialized='table'
    )
}}

/*
    fact_ncaaf_standing -- standings snapshots, one row per team per season
    per VERSION. A snapshot fact, not a state table: the weekly scd2
    versions are the point (what the standings said in week 6 is a real
    thing to know), and is_current marks the live row.

    Every query that wants "the standings" filters is_current; historical
    questions filter a validity window. This is the NFL standings shape,
    with the college specifics: the conference rides on the ROW (season
    accurate, unlike dim_ncaaf_team's current membership), wins is NULL on
    preseason rows, and the record strings are parsed tie-capable.

    win_percentage passes through from the source rather than being
    recomputed: the source's number survives the preseason NULL-wins state
    correctly, and seeding-adjacent numbers are theirs to publish
    (the NFL playoff_seed lesson).
*/

select
    s.standing_version_key,
    s.team_key,
    s.team_id,
    s.conference_key,
    s.conference_id,
    s.conference_name,
    s.season,

    s.wins,
    s.losses,
    s.win_percentage,
    s.games_behind,

    s.home_record,
    {{ ncaaf_parse_record('s.home_record', 'wins') }}        as home_wins,
    {{ ncaaf_parse_record('s.home_record', 'losses') }}      as home_losses,
    s.away_record,
    {{ ncaaf_parse_record('s.away_record', 'wins') }}        as away_wins,
    {{ ncaaf_parse_record('s.away_record', 'losses') }}      as away_losses,
    s.conference_record,
    {{ ncaaf_parse_record('s.conference_record', 'wins') }}  as conference_wins,
    {{ ncaaf_parse_record('s.conference_record', 'losses') }} as conference_losses,

    s.valid_from,
    s.valid_to,
    s.is_current

from {{ ref('stg_ncaaf__standings') }} s
