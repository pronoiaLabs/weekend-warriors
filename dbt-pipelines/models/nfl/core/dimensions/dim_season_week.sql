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

    Week character, derived from dim_game: bye_team_count is 32 minus the
    clubs that play, REGULAR SEASON ONLY -- in the preseason nobody calls an
    idle week a bye, and in the postseason an absent team is eliminated, not
    resting, so both carry NULL rather than a misleading number.
    international_game_count counts the week's games in is_international
    stadiums (0 is a real answer here: a complete slate with no such game).
    Pairs with fact_team_season.bye_week: the fact answers "when is this
    team's bye," this answers "how thin is this week's slate."
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

),

-- home/away unpivoted so each club counts once however it appears; games are
-- counted distinct so the unpivot cannot double them
week_games as (

    select season, week, season_type, game_key, stadium_key,
           home_team_key                                as team_key
    from {{ ref('dim_game') }}

    union all

    select season, week, season_type, game_key, stadium_key,
           away_team_key
    from {{ ref('dim_game') }}

),

week_character as (

    select
        g.season,
        g.week,
        g.season_type,
        count(distinct g.team_key)                      as teams_playing,
        count(distinct iff(s.is_international, g.game_key, null))
                                                        as international_game_count
    from week_games g
    left join {{ ref('dim_stadium') }} s
        on s.stadium_key = g.stadium_key
    group by 1, 2, 3

)

select
    {{ dbt_utils.generate_surrogate_key(['w.season', 'w.week', 'w.season_type']) }} as season_week_key,

    w.season,
    w.week,
    w.season_type,
    w.season_type_name,
    w.is_postseason,

    -- display label, disambiguated by season type so 2024 preseason week 1 and
    -- 2024 regular season week 1 never render identically
    w.season || ' ' ||
        case w.season_type
            when 1 then 'Pre W'
            when 2 then 'W'
            when 3 then 'Post W'
            else '? W'
        end || w.week                                           as season_week_label,

    w.week_start_date,
    w.week_end_date,
    w.games_in_week,

    -- week character (see header): byes are a regular-season concept only
    iff(w.season_type = 2, 32 - wc.teams_playing, null)         as bye_team_count,
    wc.international_game_count,

    -- ordering across an entire season, since week numbers restart per phase
    row_number() over (
        order by w.season, w.season_type, w.week
    )                                                           as season_week_sequence

from weeks w
inner join week_character wc
    on  wc.season      = w.season
    and wc.week        = w.week
    and wc.season_type = w.season_type
