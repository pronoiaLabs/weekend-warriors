{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__games -- one row per game, 2023 season onward including the
    current season's unplayed schedule.

    Home and away sit side by side here, matching the source. The unpivot to
    team x game grain happens downstream in fact_team_game, not here -- prep
    stays a faithful 1:1 view of the source shape.

    Unlike the pre-2026 shape of this source, not every row is a finished
    game. Completed games are status 'Final' or 'Final/OT'; scheduled games
    carry a kickoff-time string ('9/13 - 1:00 PM EDT') or 'TBD' for
    late-season flex slots, and a live in-progress value could land mid-load.
    is_completed is therefore derived POSITIVELY, as membership in the two
    known final statuses, so any unexpected new value lands as not-completed
    rather than breaking a value list.

    Scores are nulled for anything not completed. The source writes NULL
    scores on scheduled rows today, so the iff() is belt and suspenders --
    it also protects against the provider switching to 0-0 placeholders the
    way the WNBA games source does.

    season_type is decoded to a label: 1 = Preseason, 2 = Regular Season,
    3 = Postseason.
*/

with source as (

    select * from {{ source('nfl_raw', 'games') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['id']) }}       as game_key,
        id                                                  as game_id,

        -- when
        date                                                as game_datetime,
        date::date                                          as game_date,
        season,
        week,
        season_type,
        case season_type
            when 1 then 'Preseason'
            when 2 then 'Regular Season'
            when 3 then 'Postseason'
            else 'Unknown'
        end                                                 as season_type_name,
        postseason                                          as is_postseason,

        -- where / what
        nullif(trim(venue), '')                             as venue,
        nullif(trim(summary), '')                           as game_summary,
        status                                              as game_status,
        (status in ('Final', 'Final/OT'))                   as is_completed,
        (status = 'Final/OT')                               as went_to_overtime,

        -- participants
        {{ dbt_utils.generate_surrogate_key(['home_team__id']) }}    as home_team_key,
        home_team__id                                       as home_team_id,
        {{ dbt_utils.generate_surrogate_key(['visitor_team__id']) }} as away_team_key,
        visitor_team__id                                    as away_team_id,

        -- outcome. Nulled unless the game is completed -- see header.
        iff(status in ('Final', 'Final/OT'), home_team_score, null)
                                                            as home_team_score,
        iff(status in ('Final', 'Final/OT'), visitor_team_score, null)
                                                            as away_team_score,

        -- quarter-by-quarter, same guard
        iff(status in ('Final', 'Final/OT'), home_team_q1, null)    as home_team_q1,
        iff(status in ('Final', 'Final/OT'), home_team_q2, null)    as home_team_q2,
        iff(status in ('Final', 'Final/OT'), home_team_q3, null)    as home_team_q3,
        iff(status in ('Final', 'Final/OT'), home_team_q4, null)    as home_team_q4,
        iff(status in ('Final', 'Final/OT'), home_team_ot, null)    as home_team_ot,
        iff(status in ('Final', 'Final/OT'), visitor_team_q1, null) as away_team_q1,
        iff(status in ('Final', 'Final/OT'), visitor_team_q2, null) as away_team_q2,
        iff(status in ('Final', 'Final/OT'), visitor_team_q3, null) as away_team_q3,
        iff(status in ('Final', 'Final/OT'), visitor_team_q4, null) as away_team_q4,
        iff(status in ('Final', 'Final/OT'), visitor_team_ot, null) as away_team_ot

    from source

)

select * from renamed
