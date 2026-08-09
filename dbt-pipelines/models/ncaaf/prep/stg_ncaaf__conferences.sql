{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__conferences -- one row per conference, 25 rows, FBS and FCS.

    The subdivision split is derived from the id ranges (1-11 FBS including
    'FBS Indep.', 12-25 FCS), verified against the live API during the
    ingestion loop. The source has no subdivision field of its own; this is
    the only place the classification is written, and dim_ncaaf_team inherits
    it through the join rather than re-deriving it.

    ABBREVIATION equals NAME on every row in the source, so only one is kept.
*/

with source as (

    select * from {{ source('ncaaf_raw', 'conferences') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['id']) }}       as conference_key,
        id                                                   as conference_id,
        name                                                 as conference_name,

        -- Verified id ranges; a 26th conference would land as NULL and fail
        -- the not_null test rather than silently joining a subdivision.
        case
            when id between 1 and 11 then 'FBS'
            when id between 12 and 25 then 'FCS'
        end                                                  as subdivision,
        (id between 1 and 11)                                as is_fbs

    from source

)

select * from renamed
