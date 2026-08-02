{{
    config(
        materialized='table'
    )
}}

/*
    dim_play_type -- play classification. Grain: play type. 39 rows.

    Built from the distinct type values on plays. The source has no separate
    play-type reference table, so this is derived; if a new play type appears in
    a future load it shows up here automatically.

    play_category rolls the 39 source types into the groups analysts filter by.
    The match is on lowercased slug substrings because the source slugs are
    granular ('pass-incompletion', 'sack', 'rush', 'field-goal-good' and so on)
    and the useful grouping is coarser.
*/

with plays as (

    select distinct
        play_type_slug,
        play_type_abbreviation,
        play_type_text
    from {{ ref('stg_nfl__plays') }}
    where play_type_slug is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['play_type_slug']) }} as play_type_key,

    play_type_slug,
    play_type_abbreviation,
    play_type_text,

    case
        when lower(play_type_slug) like '%pass%'
          or lower(play_type_slug) like '%sack%'          then 'Passing'
        when lower(play_type_slug) like '%rush%'          then 'Rushing'
        when lower(play_type_slug) like '%punt%'          then 'Punt'
        when lower(play_type_slug) like '%field-goal%'
          or lower(play_type_slug) like '%extra-point%'   then 'Kicking'
        when lower(play_type_slug) like '%kickoff%'       then 'Kickoff'
        when lower(play_type_slug) like '%penalty%'       then 'Penalty'
        when lower(play_type_slug) like '%timeout%'
          or lower(play_type_slug) like '%end%'
          or lower(play_type_slug) like '%two-minute%'    then 'Administrative'
        when lower(play_type_slug) like '%fumble%'
          or lower(play_type_slug) like '%interception%'  then 'Turnover'
        else 'Other'
    end                                                 as play_category,

    -- administrative rows are clock/bookkeeping events, not football plays;
    -- most rate calculations should exclude them
    case
        when lower(play_type_slug) like '%timeout%'
          or lower(play_type_slug) like '%end%'
          or lower(play_type_slug) like '%two-minute%'    then false
        else true
    end                                                 as is_live_ball_play

from plays
