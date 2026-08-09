{{
    config(
        materialized='table'
    )
}}

/*
    dim_ncaaf_conference -- one row per conference. Grain: conference,
    25 rows, SCD1.

    College-specific: neither the NFL nor the WNBA has a conference
    dimension (the NFL's conference is an enum on the team). Here the
    conference is first-class because realignment makes the list itself
    data, standings are published per conference, and the FBS/FCS
    subdivision hangs off it.
*/

select
    conference_key,
    conference_id,
    conference_name,
    subdivision,
    is_fbs
from {{ ref('stg_ncaaf__conferences') }}
