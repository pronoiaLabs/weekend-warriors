{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__games -- one row per game, 2023-2025 seasons.

    Home and away sit side by side here, matching the source. The unpivot to
    team x game grain happens downstream in fact_team_game, not here -- prep
    stays a faithful 1:1 view of the source shape.

    All 1,002 rows are Final or Final/OT, so there is no in-progress game to
    filter out. season_type is decoded to a label: 1 = Preseason (147 games),
    2 = Regular Season (816), 3 = Postseason (39).
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
        (status = 'Final/OT')                               as went_to_overtime,

        -- participants
        {{ dbt_utils.generate_surrogate_key(['home_team__id']) }}    as home_team_key,
        home_team__id                                       as home_team_id,
        {{ dbt_utils.generate_surrogate_key(['visitor_team__id']) }} as away_team_key,
        visitor_team__id                                    as away_team_id,

        -- outcome
        home_team_score,
        visitor_team_score                                  as away_team_score,

        -- quarter-by-quarter
        home_team_q1,
        home_team_q2,
        home_team_q3,
        home_team_q4,
        home_team_ot,
        visitor_team_q1                                     as away_team_q1,
        visitor_team_q2                                     as away_team_q2,
        visitor_team_q3                                     as away_team_q3,
        visitor_team_q4                                     as away_team_q4,
        visitor_team_ot                                     as away_team_ot

    from source

)

select * from renamed
