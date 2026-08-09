{{
    config(
        materialized='table'
    )
}}

/*
    dim_ncaaf_team -- every team the source references. Grain: team,
    536 rows, SCD1.

    Only ~134 rows are FBS programs; the rest are FCS and below, kept
    because games and stats reference them by id (an FBS team's September
    schedule routinely includes an FCS opponent). Filter on is_fbs, the
    same move as the WNBA's is_franchise.

    Conference membership here is CURRENT (SCD1): realignment history is
    not in the source's team object. fact_ncaaf_standing's conference is
    season-accurate, because the standings rows carry their own conference.
*/

select
    t.team_key,
    t.team_id,
    t.college,
    t.team_name,
    t.team_full_name,
    t.team_abbreviation,
    t.team_type,
    t.is_fbs,

    t.conference_key,
    t.conference_id,
    c.conference_name,
    c.subdivision

from {{ ref('stg_ncaaf__teams') }} t
left join {{ ref('stg_ncaaf__conferences') }} c
       on t.conference_id = c.conference_id
