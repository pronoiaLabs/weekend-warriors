{{
    config(
        materialized='table'
    )
}}

/*
    dim_wnba_team -- every team the source references, 35 rows. Grain: team. SCD1.

    Only 17 rows are franchises. The other 18 are All-Star squads, national
    sides and TBD placeholders, carried rather than filtered because games,
    box scores and standings all reference them by id -- dropping them here
    would leave fact_wnba_team_game with an unresolvable team_key for the All-Star
    game. team_type classifies; consumers filter on is_franchise.

    CONFERENCE is populated for 15 of 35 rows only (the original franchises),
    so it cannot be used to decide what a row is and cannot be tested
    not_null. The classification is done upstream in stg_wnba__teams over
    explicit ids, with the team name in a trailing comment on each branch.

    TWO DEVIATIONS FROM dim_wnba_team ON THE NFL SIDE, both forced by the data:

      * team_abbreviation is NOT unique. The two placeholder rows both spell
        it 'TBD', giving 34 distinct values over 35 rows, so the yml tests it
        not_null only. Use team_key or team_id to identify a team.
      * there is no division. The WNBA has conferences and no divisions, so
        the NFL conference_division concatenation has no counterpart.

    is_defunct marks the two folded franchises, Sacramento Monarchs (2009) and
    Houston Comets (2008). They still carry standings rows back to 2008, so
    they are franchises, just not current ones -- a "how many teams are there"
    question wants is_franchise and not is_defunct together.
*/

select
    team_key,
    team_id,

    -- identity
    team_abbreviation,
    team_full_name,
    team_city,
    team_nickname,

    -- classification
    team_type,
    is_franchise,
    is_defunct,

    -- NULL for the 20 rows that are not original franchises, which includes
    -- the two 2026 expansion clubs. Season-accurate conference lives on
    -- stg_wnba__standings instead.
    conference

from {{ ref('stg_wnba__teams') }}
