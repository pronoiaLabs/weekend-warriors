{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__teams -- the 32 NFL teams.

    Static reference data, the cleanest source in the set. Nothing to strip
    beyond the dlt bookkeeping columns.
*/

with source as (

    select * from {{ source('nfl_raw', 'teams') }}

),

renamed as (

    select
        -- surrogate key
        {{ dbt_utils.generate_surrogate_key(['id']) }}  as team_key,

        -- natural key, retained for debugging and for joining back to RAW
        id                                              as team_id,

        -- attributes
        abbreviation                                    as team_abbreviation,
        full_name                                       as team_full_name,
        location                                        as team_location,
        name                                            as team_nickname,
        conference,
        division,

        -- conference + division is how the NFL is actually organised, and it is
        -- the grouping most standings questions reach for
        conference || ' ' || division                    as conference_division

    from source

)

select * from renamed
