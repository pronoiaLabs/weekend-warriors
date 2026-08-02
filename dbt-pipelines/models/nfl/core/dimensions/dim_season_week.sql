{{
    config(
        materialized='table'
    )
}}

/*
    dim_season_week -- the NFL calendar. Grain: season x week x season_type.

    78 rows: 3 seasons x (4 preseason + 18 regular + up to 5 postseason weeks).

    Built from games, which is the only source that distinguishes preseason from
    regular season. This matters: week 1 exists in BOTH the preseason and the
    regular season, so (season, week) alone is ambiguous and (season, week,
    postseason_flag) is too -- preseason and regular season share
    postseason = false. Only season_type disambiguates, which is why it is part
    of the key. Using the boolean instead would silently collapse 78 weeks into
    66 and merge preseason results into regular-season ones.

    NFL analysis is week-based rather than date-based, so this dimension carries
    the analytical weight dim_date normally would.
*/

with games as (

    select
        season,
        week,
        season_type,
        season_type_name,
        is_postseason,
        game_date
    from {{ ref('stg_nfl__games') }}

),

weeks as (

    select
        season,
        week,
        season_type,
        season_type_name,
        is_postseason,
        min(game_date)  as week_start_date,
        max(game_date)  as week_end_date,
        count(*)        as games_in_week
    from games
    group by 1, 2, 3, 4, 5

)

select
    {{ dbt_utils.generate_surrogate_key(['season', 'week', 'season_type']) }} as season_week_key,

    season,
    week,
    season_type,
    season_type_name,
    is_postseason,

    -- display label, disambiguated by season type so 2024 preseason week 1 and
    -- 2024 regular season week 1 never render identically
    season || ' ' ||
        case season_type
            when 1 then 'Pre W'
            when 2 then 'W'
            when 3 then 'Post W'
            else '? W'
        end || week                                             as season_week_label,

    week_start_date,
    week_end_date,
    games_in_week,

    -- ordering across an entire season, since week numbers restart per phase
    row_number() over (
        order by season, season_type, week
    )                                                           as season_week_sequence

from weeks
