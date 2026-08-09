{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__standings -- final standings, one row per team per season.

    dlt loads this as SCD2, so the source carries _dlt_valid_from /
    _dlt_valid_to. This view takes the CURRENT version only (valid_to is
    null), collapsing the grain to team x season for downstream use. Today
    that filter is a no-op, since all 235 rows are the first version, but it
    is the filter that keeps the grain stable once the daily reload starts
    superseding rows.

    This is the only multi-season table in the WNBA set: 235 rows across all
    19 seasons from 2008 to 2026, where every other source is 2026 only. That
    makes it the one place a year-over-year question can be answered, and it
    is why the defunct Monarchs and Comets are kept in stg_wnba__teams.

    The split records arrive as text ("11-6"). Basketball has no ties, so
    wnba_parse_record takes only wins and losses; asking it for a third
    component raises at compile time rather than returning a silent zero.
    Wins, losses and win_percentage are already numeric in the source and are
    passed through rather than recomputed, so the source stays authoritative
    on its own rounding.

    GAMES_BEHIND is a dlt variant twin: 228 rows landed as NUMBER and 7 as
    FLOAT, split into GAMES_BEHIND and GAMES_BEHIND__V_DOUBLE. Verified
    mutually exclusive -- zero rows populate both -- so wnba_coalesce_variant
    is lossless. Reading only the base column would silently null out every
    half-game deficit, which is the majority of the interesting values.

    PLAYOFF_SEED here is a genuine conference seed, unlike the NFL source's
    same-named column: it runs 1-8 and is populated for every row.
*/

with source as (

    select * from {{ source('wnba_raw', 'standings') }}

),

current_version as (

    select * from source
    where _dlt_valid_to is null

),

renamed as (

    select
        -- grain: team x season
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season']) }} as team_season_key,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}           as team_key,
        team__id                                                      as team_id,
        season,

        -- the conference the team played in THAT season, which is the
        -- historically accurate one; stg_wnba__teams carries only the current
        nullif(trim(conference), '')                                  as conference,

        -- overall record (numeric in source)
        wins,
        losses,
        wins + losses                                                 as games_played,
        win_percentage,

        -- recomputed from the components, for anyone who needs full precision
        -- rather than the source's three decimal places. Kept beside
        -- win_percentage rather than replacing it.
        {{ wnba_win_pct('wins', 'losses') }}                          as win_pct_computed,

        -- Split records, parsed from "W-L" text. No tie component: see header.
        {{ wnba_parse_record('home_record', 'wins') }}                 as home_wins,
        {{ wnba_parse_record('home_record', 'losses') }}               as home_losses,
        {{ wnba_parse_record('away_record', 'wins') }}                 as away_wins,
        {{ wnba_parse_record('away_record', 'losses') }}               as away_losses,
        {{ wnba_parse_record('conference_record', 'wins') }}           as conference_wins,
        {{ wnba_parse_record('conference_record', 'losses') }}         as conference_losses,

        -- postseason position
        playoff_seed,
        {{ wnba_coalesce_variant('games_behind') }}                    as games_behind,

        -- source text retained for audit
        home_record,
        away_record,
        conference_record

    from current_version

)

select * from renamed
