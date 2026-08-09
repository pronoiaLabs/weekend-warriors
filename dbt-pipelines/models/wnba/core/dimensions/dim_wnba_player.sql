{{
    config(
        materialized='table'
    )
}}

/*
    dim_wnba_player -- player biographical attributes, 860 rows. Grain: player. SCD1.

    IT CARRIES A TEAM, AND THAT IS A DELIBERATE DEVIATION FROM dim_wnba_player ON
    THE NFL SIDE, which excludes team on the grounds that a current-team
    column lets a 2023 query return a 2025 team and look correct. Three things
    make the trade come out the other way here:

      1. WNBA coverage is a single season. Every game-grain and season-grain
         source in this set is 2026 only (standings is the lone exception and
         carries its own team_key), so "current team" and "the team she played
         for that season" are the same team. There is no earlier season for a
         stale value to corrupt.
      2. The season-advanced sources carry NO team at all. Five of them
         (stg_wnba__player_season_advanced, _scoring, _usage, _misc,
         _defense) are player x season with no team column, so a
         "team leaders in true shooting" question has nowhere else to get an
         affiliation from. Without this column it is unanswerable.
      3. The columns are named current_team_*, not team_*, so a consumer
         reading the schema is told what they are.

    The moment a second season lands this becomes wrong in the way the NFL
    comment describes. Per-game affiliation is already correct without it:
    fact_wnba_player_game.team_key is the team the player appeared for in THAT
    game, and it is the column to prefer whenever the grain allows.

    NO WEIGHT AND NO COLLEGE. Both are quarantined upstream in
    stg_wnba__players: the loader shifts the college name into the WEIGHT
    field whenever a weight is missing, so 0 of 860 rows carry a numeric
    weight and COLLEGE itself is NULL for 752. They are absent rather than
    exposed as columns that look usable and are not.

    Coverage is thin and worth knowing before building on top:
      860 players total
      320 have a height on file
      319 an age
      531 a jersey number
      130 sit on the explicit unknown position member

    position_name is DERIVED FROM THE ABBREVIATION, following dim_wnba_player on
    the NFL side and for the same reason: the source's POSITION column carries
    two vocabularies at once, 191 rows saying 'Guard' against 169 saying 'G'
    for the same thing. Cortex Analyst filters on literal values, so a split
    enum silently returns half the guards. position_abbreviation is the
    single-vocabulary column (G / F / C / NA) and is the authoritative input.
    The raw label is retained as position_source for audit only and should not
    be exposed in a semantic view.
*/

with players as (

    select * from {{ ref('stg_wnba__players') }}

),

teams as (

    select
        team_id,
        team_abbreviation
    from {{ ref('stg_wnba__teams') }}

)

select
    p.player_key,
    p.player_id,

    -- identity
    p.full_name,
    p.first_name,
    p.last_name,
    p.jersey_number,

    -- position. Four members, one of them the explicit unknown.
    p.position_abbreviation,
    case p.position_abbreviation
        when 'G' then 'Guard'
        when 'F' then 'Forward'
        when 'C' then 'Center'
        else 'Unknown'
    end                                     as position_name,
    p.position                              as position_source,
    p.has_known_position,

    -- physical. NULL for the 540 players with no height and 541 with no age.
    p.height_inches,
    p.age,

    -- current affiliation -- see header. Named current_* on purpose.
    p.current_team_key,
    p.current_team_id,
    t.team_abbreviation                     as current_team_abbreviation

from players p
left join teams t
    on p.current_team_id = t.team_id
