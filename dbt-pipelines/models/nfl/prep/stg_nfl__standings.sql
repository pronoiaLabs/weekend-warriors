{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__standings -- final standings, one row per team per season.

    dlt loads this as SCD2, so the source carries _dlt_valid_from /
    _dlt_valid_to. This view takes the CURRENT version only (valid_to is null),
    collapsing the grain to team x season for downstream use.

    The record columns arrive as text ("11-6", "5-1"). Wins/losses/ties are
    already numeric in the source, so overall_record is redundant and dropped;
    the conference/division/home/road records have no numeric siblings, so they
    are parsed here.
*/

with source as (

    select * from {{ source('nfl_raw', 'standings') }}

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

        -- overall record (numeric in source)
        wins,
        losses,
        ties,
        {{ nfl_win_pct('wins', 'losses', 'ties') }}                    as win_pct,

        -- scoring
        points_for,
        points_against,
        point_differential,

        -- Split records, parsed from "W-L" / "W-L-T" text.
        --
        -- The tie component matters. A 2025 record of "4-7-1" covers 12 games,
        -- so taking only wins and losses leaves 11 and anyone computing
        -- conference win pct as w/(w+l) gets 0.364 instead of the correct 0.375.
        -- nfl_parse_record returns 0 (not NULL) for a missing third part, since
        -- an absent tie component means zero ties.
        {{ nfl_parse_record('conference_record', 'wins') }}            as conference_wins,
        {{ nfl_parse_record('conference_record', 'losses') }}          as conference_losses,
        {{ nfl_parse_record('conference_record', 'ties') }}            as conference_ties,
        {{ nfl_parse_record('division_record', 'wins') }}              as division_wins,
        {{ nfl_parse_record('division_record', 'losses') }}            as division_losses,
        {{ nfl_parse_record('division_record', 'ties') }}              as division_ties,
        {{ nfl_parse_record('home_record', 'wins') }}                  as home_wins,
        {{ nfl_parse_record('home_record', 'losses') }}                as home_losses,
        {{ nfl_parse_record('home_record', 'ties') }}                  as home_ties,
        {{ nfl_parse_record('road_record', 'wins') }}                  as road_wins,
        {{ nfl_parse_record('road_record', 'losses') }}                as road_losses,
        {{ nfl_parse_record('road_record', 'ties') }}                  as road_ties,

        -- postseason position.
        --
        -- The source column is named playoff_seed but it is NOT a playoff seed:
        -- it is a conference standing rank running 1-16 and populated for EVERY
        -- team (verified 16 ranks x 6 team-seasons = 96 rows, no NULLs). Renamed
        -- to conference_rank so it cannot be mistaken for a seed.
        --
        -- Playoff qualification is therefore rank <= 7, since seven teams per
        -- conference make the postseason. Deriving it from NULLability -- the
        -- obvious reading of the source name -- would mark all 32 teams as
        -- playoff qualifiers.
        playoff_seed                                                  as conference_rank,
        (playoff_seed <= 7)                                           as made_playoffs,
        iff(playoff_seed <= 7, playoff_seed, null)                    as playoff_seed,
        win_streak,

        -- source text retained for audit
        overall_record,
        conference_record,
        division_record,
        home_record,
        road_record

    from current_version

)

select * from renamed
