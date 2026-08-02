{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__plays -- play-by-play, one row per play. 179,402 rows.

    This view is where stripping the dlt flattening pays off most. The source
    carries 69 columns, 38 of which are a copy of the game record and both
    teams' details repeated on every one of the 179k plays. Only game_id and
    team_id survive.

    Two source quirks preserved deliberately:
      * team_id is NULLABLE. 126 plays are neutral events (kickoffs and
        similar) with no possessing team. Not a data error.
      * 18 games have no plays at all, so fact_play does not cover every game.

    clock_display arrives as "14:32" (time remaining in the period) and is
    parsed to seconds so it can be used in ordering and situational filters.
*/

with source as (

    select * from {{ source('nfl_raw', 'plays') }}

),

renamed as (

    select
        -- grain: play. Note id is TEXT in this source, not numeric.
        {{ dbt_utils.generate_surrogate_key(['id']) }}            as play_key,
        id                                                       as play_id,

        -- foreign keys
        {{ dbt_utils.generate_surrogate_key(['game__id']) }}      as game_key,
        game__id                                                 as game_id,

        -- nullable: neutral-event plays have no possessing team
        case when team__id is not null
             then {{ dbt_utils.generate_surrogate_key(['team__id']) }}
        end                                                      as team_key,
        team__id                                                 as team_id,

        -- play classification
        {{ dbt_utils.generate_surrogate_key(['type_slug']) }}     as play_type_key,
        type_slug                                                as play_type_slug,
        type_abbreviation                                         as play_type_abbreviation,
        type_text                                                as play_type_text,

        -- natural-language description. Candidate for a Cortex Search service
        -- later ("find plays where X happened").
        text                                                     as play_description,
        short_text                                               as play_description_short,

        -- situation: where the play started
        period,
        clock_display,
        -- "14:32" -> 872 seconds remaining in the period
        case
            when clock_display like '%:%'
                then split_part(clock_display, ':', 1)::int * 60
                     + split_part(clock_display, ':', 2)::int
        end                                                      as clock_seconds_remaining,
        start_down,
        start_distance,
        start_yard_line,
        start_yards_to_endzone,

        -- situation: where the play ended
        end_down,
        end_distance,
        end_yard_line,
        end_yards_to_endzone,
        end_down_distance_text,
        end_short_down_distance_text,
        end_possession_text,

        -- outcome
        stat_yardage                                             as yards_gained,
        scoring_play                                             as is_scoring_play,
        home_score                                               as home_score_after_play,
        away_score                                               as away_score_after_play,
        home_win_probability,

        -- derived situational flags, the ones situational analysis always wants
        (start_down = 3)                                         as is_third_down,
        (start_down = 4)                                         as is_fourth_down,
        (start_yards_to_endzone <= 20)                           as is_red_zone,

        wallclock                                                as play_wallclock,

        -- carried through so fact_play can build incrementally
        _dlt_load_id

    from source

)

select * from renamed
