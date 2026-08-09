{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__teams -- one row per team, 536 rows, FBS through FCS and below.

    CLASSIFIES EVERY ROW, FILTERS NONE (the WNBA is_franchise pattern): only
    ~134 rows are FBS programs, and most consumers want that slice, but games
    and stats reference the rest by id so they stay. is_fbs is the filter
    almost every consumer wants.

    CONFERENCE is the source's bare numeric id (its own spec wrongly says
    string) and is NULL for 29 rows, so team_type has an explicit
    'Unaffiliated' member rather than a NULL bucket. Subdivision follows the
    conference id ranges recorded in stg_ncaaf__conferences.

    COLLEGE is the institution ('Boston College'), NAME the mascot ('Eagles'),
    FULL_NAME the pairing. All three pass through; college is what a person
    means by "the team".
*/

with source as (

    select * from {{ source('ncaaf_raw', 'teams') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['id']) }}       as team_key,
        id                                                   as team_id,
        college,
        name                                                 as team_name,
        full_name                                            as team_full_name,
        abbreviation                                         as team_abbreviation,

        -- NULL-safe: a surrogate key hashed from NULL is a real-looking key
        -- that resolves to nothing, so unaffiliated teams keep a NULL key.
        iff(conference is not null,
            {{ dbt_utils.generate_surrogate_key(['conference']) }},
            null)                                            as conference_key,
        conference                                           as conference_id,

        case
            when conference between 1 and 11 then 'FBS'
            when conference between 12 and 25 then 'FCS'
            else 'Unaffiliated'
        end                                                  as team_type,
        coalesce(conference between 1 and 11, false)         as is_fbs

    from source

)

select * from renamed
