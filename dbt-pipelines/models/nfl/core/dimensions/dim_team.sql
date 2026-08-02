{{
    config(
        materialized='table'
    )
}}

/*
    dim_team -- the 32 NFL teams. Grain: team.

    A pure SCD1 dimension over static reference data. Teams do relocate and
    rebrand in reality, but this source carries only current names and covers
    only 2023-2025, so there is no history to track.
*/

select
    team_key,
    team_id,

    team_abbreviation,
    team_full_name,
    team_location,
    team_nickname,

    conference,
    division,
    conference_division

from {{ ref('stg_nfl__teams') }}
