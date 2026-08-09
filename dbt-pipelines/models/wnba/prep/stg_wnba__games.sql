{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__games -- one row per game, 333 rows, 2026 season only.

    Home and away sit side by side here, matching the source. The unpivot to
    team x game grain happens downstream in fact_wnba_team_game, not here -- prep
    stays a faithful 1:1 view of the source shape.

    Unlike the NFL games source, this one is not all finished games. 240 rows
    are STATUS 'post' and 93 are 'pre' (scheduled, through 2026-09-25). A live
    in-progress status is possible mid-load, since a load can land while a
    game is being played, so status is passed through as a label rather than
    being decoded into a closed vocabulary.

    Scores are nulled for anything not STATUS 'post'. The source writes 0-0,
    not NULL, into all 93 scheduled rows, so carrying them straight through
    would drop 93 fake shutouts into every average downstream.

    One completed game is a special case worth knowing about: id 24935 on
    2026-07-17 is STATUS 'post' with STATUS_STATE 'postponed' and a 0-0 line.
    It is therefore is_completed with no result, and winner_team_id is NULL
    for it because the scores tie.

    season_type_name is derived here rather than by wnba_season_type_name(),
    because GAMES carries only a POSTSEASON boolean and the All-Star and
    Preseason cases need game context the macro does not have.
*/

with source as (

    select * from {{ source('wnba_raw', 'games') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['id']) }}       as game_key,
        id                                                  as game_id,

        -- when. The source lands UTC; game_datetime_et is the same instant in
        -- US Eastern, the league's publishing convention. Derived here rather
        -- than at read time so every consumer inherits one display
        -- convention. convert_timezone handles the DST boundary.
        date                                                as game_datetime,
        convert_timezone('America/New_York', date)          as game_datetime_et,
        date::date                                          as game_date,
        season,

        -- ---------------------------------------------------------------
        -- season type
        --
        -- Four-way classification over a single boolean plus context.
        --
        -- All-Star first, because an All-Star game is not postseason and its
        -- date sits mid-season, so either later branch would claim it. The id
        -- list is the non-competition set from stg_wnba__teams: every row
        -- there whose team_type is All-Star, National or Placeholder. The two
        -- lists are duplicated on purpose (prep does not join a dimension to
        -- classify itself) and must be changed together. Today it matches
        -- exactly one row: id 24955, TEAM COOP vs TEAM SPOON on 2026-07-26.
        --
        -- Preseason is decided by a hardcoded opener date. Evidence for
        -- 2026-05-08: it is the earliest DATE in the source, every game from
        -- it onward has TEAM_STATS rows (238 of 240 completed games, the two
        -- gaps being same-day 2026-08-08 games the box-score load has not
        -- reached yet), and standings games played for 2026 sums to 470
        -- team-games, exactly the count of final games dated 2026-05-08
        -- through 2026-08-07, the standings snapshot's as-of date. So no
        -- dated game is an exhibition and this branch matches zero rows
        -- today; it exists so a preseason game in a later load lands in the
        -- right bucket instead of inflating the regular season. The singular
        -- reconciliation test guards the number.
        -- ---------------------------------------------------------------
        case
            when home_team__id in (16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
                                   26, 27, 28, 29, 32, 33, 34, 35)
              or visitor_team__id in (16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
                                      26, 27, 28, 29, 32, 33, 34, 35)
                then 'All-Star'
            when postseason then 'Postseason'
            when date::date < '2026-05-08'::date then 'Preseason'
            else 'Regular Season'
        end                                                 as season_type_name,
        postseason                                          as is_postseason,

        -- state
        status                                              as game_status,
        status_state                                        as game_state,
        (status = 'post')                                   as is_completed,

        -- PERIOD is 4 for a regulation finish and 5 or 8 for the 10 games
        -- that needed extra time; 0 on scheduled rows.
        period                                              as final_period,
        (status = 'post' and period > 4)                    as went_to_overtime,

        -- participants
        {{ dbt_utils.generate_surrogate_key(['home_team__id']) }}    as home_team_key,
        home_team__id                                       as home_team_id,
        {{ dbt_utils.generate_surrogate_key(['visitor_team__id']) }} as away_team_key,
        visitor_team__id                                    as away_team_id,

        -- outcome. Nulled unless the game has been played -- see header.
        iff(status = 'post', home_score, null)              as home_team_score,
        iff(status = 'post', away_score, null)              as away_team_score,

        -- NULL for scheduled games and for the one postponed 0-0 row.
        -- Basketball has no ties, so an equal score here means no result.
        case
            when status <> 'post' then null
            when home_score > away_score then home_team__id
            when away_score > home_score then visitor_team__id
        end                                                 as winner_team_id

    from source

)

select * from renamed
