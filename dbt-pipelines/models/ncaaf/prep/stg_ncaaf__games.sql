{{
    config(
        materialized='view'
    )
}}

/*
    stg_ncaaf__games -- one row per game, seasons 2024-2026, ~4,977 rows
    including the full 2026 scheduled slate.

    Home and away sit side by side, matching the source; the unpivot to
    team x game grain happens in fact_ncaaf_team_game.

    NAMING NORMALIZED HERE: the source pairs VISITOR_TEAM__* team blocks with
    AWAY_SCORE_* score columns. Everything downstream says home/away.

    Scores are nulled for anything not STATUS 'post'. The source writes 0-0,
    not NULL, into every scheduled row's totals (quarter scores are NULL),
    so carrying them through would drop ~1,600 fake shutouts into every
    average downstream. Completedness derives from status, never from scores.

    POSTSEASON IS WEEK 999. This sport has no season_type parameter and no
    postseason boolean; bowls and the CFP arrive in the same stream marked
    week 999. One known upstream mislabel exists (the Jan 2025 Gator Bowl
    carries week 1), tolerated rather than patched: prep stays faithful and
    the reconciliation tests know the number.

    A live in-progress status could appear mid-load (the daily 06:00 UTC run
    lands after the latest finals, but a delayed game is possible), so status
    passes through as a label rather than a closed vocabulary.
*/

with source as (

    select * from {{ source('ncaaf_raw', 'games') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['id']) }}       as game_key,
        id                                                  as game_id,

        -- when. The source lands UTC; game_datetime_et is the same instant in
        -- US Eastern, the established display convention across sports.
        -- convert_timezone handles the DST boundary.
        date                                                as game_datetime,
        convert_timezone('America/New_York', date)          as game_datetime_et,
        date::date                                          as game_date,
        season,
        week,
        (week = 999)                                        as is_postseason,

        -- state
        status                                              as game_status,
        status_state                                        as game_state,
        (status = 'post')                                   as is_completed,

        -- PERIOD is 4 for a regulation finish, >4 for overtime; 0 on
        -- scheduled rows.
        period                                              as final_period,
        (status = 'post' and period > 4)                    as went_to_overtime,

        -- participants (visitor -> away, see header)
        {{ dbt_utils.generate_surrogate_key(['home_team__id']) }}    as home_team_key,
        home_team__id                                       as home_team_id,
        {{ dbt_utils.generate_surrogate_key(['visitor_team__id']) }} as away_team_key,
        visitor_team__id                                    as away_team_id,

        -- outcome. Nulled unless played -- see header.
        iff(status = 'post', home_score, null)              as home_team_score,
        iff(status = 'post', away_score, null)              as away_team_score,
        iff(status = 'post', home_score_ot, null)           as home_team_score_ot,
        iff(status = 'post', away_score_ot, null)           as away_team_score_ot,

        -- Ties were possible historically (pre-1996); an equal final score
        -- yields NULL rather than inventing a winner.
        case
            when status <> 'post' then null
            when home_score > away_score then home_team__id
            when away_score > home_score then visitor_team__id
        end                                                 as winner_team_id

    from source

)

select * from renamed
