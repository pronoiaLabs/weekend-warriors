{{
    config(
        materialized='table'
    )
}}

/*
    dim_player -- player biographical attributes. Grain: player. SCD1.

    NO TEAM COLUMN, deliberately. The source holds only each player's current
    team, so putting it here would let a 2023 query return a player's 2025 team
    and look correct. Per-game team affiliation lives on the fact tables via
    team_key, which is accurate as loaded.

    Coverage is thin and worth knowing before building anything on top:
      13,503 players total
       3,915 ever appear in a box score
       8,379 have position 'Unknown'
         801 of those Unknown-position players DO appear in box scores

    'Unknown' / 'UNK' are carried as explicit dimension members rather than
    NULLs, which is the Kimball convention and keeps inner joins from silently
    dropping rows. has_known_position exists so consumers can filter when they
    need players with real biographical data.

    position_group rolls the 27 source positions into the four units analysts
    actually slice by, since the raw values mix specificity levels (both 'CB'
    and 'LCB' appear, as do 'OL', 'OT' and 'OG').
*/

with players as (

    select * from {{ ref('stg_nfl__players') }}

)

select
    player_key,
    player_id,

    -- identity
    full_name,
    first_name,
    last_name,
    jersey_number,

    -- Position.
    --
    -- position_name is DERIVED FROM THE ABBREVIATION, not passed through from
    -- the source. The source's own position text is not a usable enum: it
    -- contains case-variant duplicates ('Place kicker' 54 rows vs 'Place Kicker'
    -- 25 rows, splitting 79 kickers across two spellings) and in three cases the
    -- abbreviation leaked into the label field ('NT', 'WLB', 'LCB').
    --
    -- Cortex Analyst filters on literal values, so a split enum silently returns
    -- partial results -- "who are the kickers" would miss a third of them.
    -- position_abbreviation is clean and complete (25 values), so it is the
    -- authoritative input. The raw source label is retained as position_source
    -- for audit only and should not be exposed in a semantic view.
    position_abbreviation,
    case position_abbreviation
        when 'QB'  then 'Quarterback'
        when 'RB'  then 'Running Back'
        when 'FB'  then 'Fullback'
        when 'WR'  then 'Wide Receiver'
        when 'TE'  then 'Tight End'
        when 'C'   then 'Center'
        when 'G'   then 'Guard'
        when 'OG'  then 'Offensive Guard'
        when 'OT'  then 'Offensive Tackle'
        when 'OL'  then 'Offensive Lineman'
        when 'DE'  then 'Defensive End'
        when 'DT'  then 'Defensive Tackle'
        when 'DL'  then 'Defensive Lineman'
        when 'NT'  then 'Nose Tackle'
        when 'LB'  then 'Linebacker'
        when 'WLB' then 'Weakside Linebacker'
        when 'CB'  then 'Cornerback'
        when 'LCB' then 'Left Cornerback'
        when 'S'   then 'Safety'
        when 'DB'  then 'Defensive Back'
        when 'PK'  then 'Place Kicker'
        when 'P'   then 'Punter'
        when 'LS'  then 'Long Snapper'
        when 'KR'  then 'Kick Returner'
        else 'Unknown'
    end                             as position_name,
    position                        as position_source,
    case
        when position_abbreviation in ('QB', 'RB', 'FB', 'WR', 'TE') then 'Offense - Skill'
        when position_abbreviation in ('C', 'G', 'OG', 'OT', 'OL')   then 'Offense - Line'
        when position_abbreviation in ('DE', 'DT', 'DL', 'NT')       then 'Defense - Line'
        when position_abbreviation in ('LB', 'WLB')                  then 'Defense - Linebacker'
        when position_abbreviation in ('CB', 'LCB', 'S', 'DB')       then 'Defense - Secondary'
        when position_abbreviation in ('PK', 'P', 'LS', 'KR')        then 'Special Teams'
        else 'Unknown'
    end                             as position_group,
    has_known_position,

    -- physical. NULL for the 9,715 players with no measurements on file.
    height_inches,
    weight_lbs,
    age,
    seasons_experience,
    (seasons_experience = 1)        as is_rookie,

    -- background
    college

from players
