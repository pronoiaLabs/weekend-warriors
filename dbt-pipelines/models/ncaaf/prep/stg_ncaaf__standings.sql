{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__standings -- standings snapshots, versioned. THE ONLY SCD2
    SOURCE IN THIS SPORT: dlt loads /standings with merge/scd2 partitioned by
    season, so every weekly load that changes a row closes the old version
    (_DLT_VALID_TO stamped) and opens a new one. History accumulates weekly
    through the season.

    HISTORY IS KEPT HERE, filtering is downstream: fact_ncaaf_standing wants
    the versions (that is the point of a weekly snapshot), so this view
    passes validity through as valid_from / valid_to plus an is_current
    flag. Anything that wants "the standings" filters is_current.

    WINS IS NULL ON PRESEASON ROWS: the API publishes the full 0-0 slate
    before kickoff with wins null and losses 0. Not patched to zero --
    a NULL wins row is how "season not started" reads, and win_percentage
    is NULL there too (0-0 has no defined percentage).

    Grain: one row per team per conference per season VERSION. The
    conference is first-class (the only denormalized conference block in the
    source); a team that changes conference between seasons appears under
    each correctly.

    VARIANT TWINS folded here: WIN_PERCENTAGE, GAMES_BEHIND.
    Record strings (home/away/conference) pass through as text; the parsed
    components live in fact_ncaaf_standing via ncaaf_parse_record so the
    strings stay printable as-is.
*/

with source as (

    select * from {{ source('ncaaf_raw', 'standings') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season', '_dlt_valid_from']) }}
                                                            as standing_version_key,

        {{ dbt_utils.generate_surrogate_key(['team__id']) }}   as team_key,
        team__id                                            as team_id,
        {{ dbt_utils.generate_surrogate_key(['conference__id']) }}
                                                            as conference_key,
        conference__id                                      as conference_id,
        conference__name                                    as conference_name,
        season,

        wins,
        losses,
        {{ ncaaf_coalesce_variant('win_percentage') }}      as win_percentage,
        {{ ncaaf_coalesce_variant('games_behind') }}        as games_behind,
        home_record,
        away_record,
        conference_record,

        -- scd2 validity from dlt
        _dlt_valid_from                                     as valid_from,
        _dlt_valid_to                                       as valid_to,
        (_dlt_valid_to is null)                             as is_current

    from source

)

select * from renamed
