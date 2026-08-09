{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__players -- player roster, 860 rows.

    Three things to know about this source.

    1. WEIGHT and COLLEGE are quarantined, not carried. Upstream shifts the
       college name into the WEIGHT field whenever a weight is missing, so
       WEIGHT holds values like 'UConn', 'South Carolina' and '--'. Verified:
       0 of 860 rows have a numeric WEIGHT, and COLLEGE itself is NULL for 752
       of 860. Neither column can be repaired here -- the true weight was
       never landed -- so both are dropped rather than exposed as a column
       that looks usable and is not. Reinstate them only after the dlt side
       stops collapsing the two fields.

    2. It holds each player's CURRENT team only. There is no team history, so
       these columns are named current_team_*. dim_wnba_player promotes them
       as a documented approximation (the season-advanced sources carry no
       team, and with single-season coverage current team ~= season team);
       per-game team affiliation comes from stg_wnba__player_stats.team_key.

    3. POSITION carries two vocabularies at once: 191 rows say 'Guard' and 169
       say 'G' for the same thing, with 130 rows on the explicit unknown member
       'Not Available'. POSITION_ABBREVIATION is the single-vocabulary column
       (G / F / C / NA) and is the one to group by; POSITION is passed through
       for display.

    Coverage is thin. Of 860 players only 320 have a height, 319 an age and
    531 a jersey number. HEIGHT arrives in the same "6' 2\"" shape the NFL
    source uses and is parsed the same way.
*/

with source as (

    select * from {{ source('wnba_raw', 'players') }}

),

cleaned as (

    select
        id,

        nullif(trim(first_name), '')                as first_name,
        nullif(trim(last_name), '')                 as last_name,
        nullif(trim(position), '')                  as position,
        nullif(trim(position_abbreviation), '')     as position_abbreviation,
        nullif(trim(jersey_number), '')             as jersey_number,
        nullif(trim(height), '')                    as height_raw,
        age,
        team__id                                    as team_id

        -- weight and college are deliberately absent -- see header

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

        -- Kimball prefers an explicit Unknown member over NULL in a dimension.
        -- The source already supplies one, spelled 'Not Available', so the
        -- coalesce only catches a future NULL rather than rewriting today's rows.
        coalesce(position, 'Unknown')                   as position,
        coalesce(position_abbreviation, 'UNK')          as position_abbreviation,

        jersey_number,

        -- "6' 2\"" -> 74. NULL for the 540 players with no height on file.
        regexp_substr(height_raw, '^(\\d+)', 1, 1, 'e', 1)::int * 12
            + coalesce(regexp_substr(height_raw, '(\\d+)"', 1, 1, 'e', 1)::int, 0)
                                                        as height_inches,

        age,

        -- current team only -- see header. Promoted to dim_wnba_player as a
        -- documented approximation: the season-advanced sources carry no
        -- team, and with single-season coverage current team ~= season team.
        {{ dbt_utils.generate_surrogate_key(['team_id']) }} as current_team_key,
        team_id                                         as current_team_id,

        -- lets consumers filter to players with a real position on file.
        -- Reads the abbreviation, which is the single-vocabulary column, and
        -- resolves a NULL to false rather than true.
        coalesce(position_abbreviation, 'NA') not in ('NA', 'UNK')
                                                        as has_known_position

    from cleaned

)

select * from renamed
