{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__teams -- every team row the source carries, 35 of them.

    Only 17 are franchises. The other 18 are All-Star squads, national teams
    and TBD placeholders, and they are kept rather than filtered because
    games, box scores and season aggregates all reference them by id: dropping
    them here would break a foreign key downstream. team_type classifies
    instead, and consumers filter on is_franchise.

    CONFERENCE cannot drive the classification. It is populated for exactly
    the 15 original franchises (IDs 1-15) and NULL for all 20 remaining rows,
    which lumps the 2026 expansion teams in with the exhibition squads. The
    two expansion clubs, Toronto Tempo (TOR, id 30) and Portland Fire (POR,
    id 31), are real franchises that play a real schedule and appear in
    standings, so the CASE is written over explicit ids with the team name in
    a trailing comment on each branch.

    is_defunct marks the two franchises that no longer exist: Sacramento
    Monarchs (folded 2009) and Houston Comets (folded 2008). They still carry
    standings rows back to 2008, so they are franchises, just not current ones.

    CITY arrives as an empty string rather than NULL for the six rows with no
    city (the four national teams and the two expansion clubs), so it goes
    through nullif(trim(...), '') the way the NFL text attributes do.

    The non-competition ids, 16-29 plus 32-35, are duplicated in
    stg_wnba__games to decide the 'All-Star' season type. Change one list and
    the other has to change with it.
*/

with source as (

    select * from {{ source('wnba_raw', 'teams') }}

),

renamed as (

    select
        -- surrogate key
        {{ dbt_utils.generate_surrogate_key(['id']) }}  as team_key,

        -- natural key, retained for debugging and for joining back to RAW
        id                                              as team_id,

        -- attributes. Blanks arrive as '' rather than NULL, so every text
        -- column is nullif-trimmed.
        nullif(trim(abbreviation), '')                  as team_abbreviation,
        nullif(trim(full_name), '')                     as team_full_name,
        nullif(trim(city), '')                          as team_city,
        nullif(trim(name), '')                          as team_nickname,
        nullif(trim(conference), '')                    as conference,

        -- classification. NULL conference covers 20 of 35 rows, so this is
        -- written over ids, not over any source attribute.
        case
            when id between 1 and 13 then 'Franchise'   -- the 13 current original clubs
            when id = 14 then 'Franchise'               -- Sacramento Monarchs, folded 2009
            when id = 15 then 'Franchise'               -- Houston Comets, folded 2008
            when id = 30 then 'Franchise'               -- Toronto Tempo, 2026 expansion
            when id = 31 then 'Franchise'               -- Portland Fire, 2026 expansion
            when id = 16 then 'All-Star'                -- EAST
            when id = 17 then 'All-Star'                -- WEST
            when id = 18 then 'All-Star'                -- Team WNBA
            when id = 20 then 'All-Star'                -- Team Delle Donne
            when id = 21 then 'All-Star'                -- Team Parker
            when id = 22 then 'All-Star'                -- Team Wilson
            when id = 23 then 'All-Star'                -- TEAM STEWART
            when id = 24 then 'All-Star'                -- TEAM CLARK
            when id = 25 then 'All-Star'                -- TEAM COLLIER
            when id = 34 then 'All-Star'                -- TEAM COOP
            when id = 35 then 'All-Star'                -- TEAM SPOON
            when id = 19 then 'National'                -- Team USA, the national side, not an All-Star squad
            when id = 26 then 'National'                -- BRAZIL
            when id = 27 then 'National'                -- Japan
            when id = 28 then 'National'                -- Australia
            when id = 29 then 'National'                -- Puerto Rico
            when id = 32 then 'Placeholder'             -- TBD
            when id = 33 then 'Placeholder'             -- TBD
            else 'Unknown'
        end                                             as team_type,

        -- the filter nearly every downstream model wants: 17 rows
        (id between 1 and 15 or id in (30, 31))         as is_franchise,

        -- folded clubs. Still franchises, still carry standings history.
        (id in (14, 15))                                as is_defunct

    from source

)

select * from renamed
