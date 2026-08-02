{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__players -- player roster.

    Two things to know about this source:

    1. It holds each player's CURRENT team only. There is no team history, so
       team is deliberately NOT carried through to dim_player. Per-game team
       affiliation comes from stg_nfl__player_stats.team_key instead, which is
       accurate as loaded.

    2. Coverage is thin. Of 13,503 players, 8,379 have position 'Unknown' and
       9,715 have no height/weight/experience. Only 3,915 players ever appear in
       stats, and 801 of those still have an unknown position. The blanks arrive
       as empty strings, not NULLs, so every text attribute goes through
       nullif(trim(...), '').

    Casting notes: height arrives as "6' 2\"", weight as "176 lbs", experience
    as "5th Season". All three are parsed to numbers here.
*/

with source as (

    select * from {{ source('nfl_raw', 'players') }}

),

cleaned as (

    select
        id,

        nullif(trim(first_name), '')                as first_name,
        nullif(trim(last_name), '')                 as last_name,
        nullif(trim(position), '')                  as position,
        nullif(trim(position_abbreviation), '')     as position_abbreviation,
        nullif(trim(college), '')                   as college,
        nullif(trim(jersey_number), '')             as jersey_number,
        nullif(trim(height), '')                    as height_raw,
        nullif(trim(weight), '')                    as weight_raw,
        nullif(trim(experience), '')                as experience_raw,
        age,
        team__id                                    as team_id

    from source

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['id']) }}   as player_key,
        id                                              as player_id,

        first_name,
        last_name,
        trim(coalesce(first_name, '') || ' ' || coalesce(last_name, ''))
                                                        as full_name,

        -- Kimball prefers an explicit Unknown member over NULL in a dimension,
        -- so 'Unknown' is passed through as a real value rather than nulled out.
        coalesce(position, 'Unknown')                   as position,
        coalesce(position_abbreviation, 'UNK')          as position_abbreviation,

        college,
        jersey_number,

        -- "6' 2\"" -> 74
        regexp_substr(height_raw, '^(\\d+)', 1, 1, 'e', 1)::int * 12
            + coalesce(regexp_substr(height_raw, '(\\d+)"', 1, 1, 'e', 1)::int, 0)
                                                        as height_inches,

        -- "176 lbs" -> 176
        regexp_substr(weight_raw, '^(\\d+)', 1, 1, 'e', 1)::int
                                                        as weight_lbs,

        -- "5th Season" -> 5
        regexp_substr(experience_raw, '^(\\d+)', 1, 1, 'e', 1)::int
                                                        as seasons_experience,

        age,

        -- current team only -- see header. Kept here so a "who is on the roster
        -- now" question is answerable, but NOT promoted to dim_player.
        {{ dbt_utils.generate_surrogate_key(['team_id']) }} as current_team_key,
        team_id                                         as current_team_id,

        -- lets consumers filter to players with real biographical data.
        -- Reads off the raw (un-coalesced) column: a NULL position is unknown,
        -- so it must resolve to false, not true.
        coalesce(position, 'Unknown') <> 'Unknown'      as has_known_position

    from cleaned

)

select * from renamed
