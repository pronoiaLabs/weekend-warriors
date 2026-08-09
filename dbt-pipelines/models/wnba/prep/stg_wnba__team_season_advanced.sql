{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__team_season_advanced -- season-level team efficiency and rates.

    Grain: team x season. 15 rows, 2026 regular season only, one row per
    active franchise.

    Column vocabulary matches stg_wnba__player_season_advanced wherever the
    same metric exists, so a player can be compared to her team without a
    translation step. The team table carries no AGE, no TEAM_COUNT, no
    FGA/FGM and no usage rate, and no SP_WORK_* tracking ratings; everything
    else lines up.

    THE RANK COLUMNS ARE DROPPED. 19 of the 58 source columns are *_RANK, a
    precomputed league rank for the metric beside them. A rank is only valid
    over the population it was computed on, and it survives any filter a
    query applies, so it lies as soon as the scope narrows. Ordering by the
    metric re-derives it correctly at any scope.

    Over 15 teams the ranks are also trivially reproducible, which is a
    second reason not to store them.

    FOUR CONSTANT COLUMNS ARE DROPPED. Verified with SELECT DISTINCT over all
    15 rows: SCOPE = 'general', MEASURE_TYPE = 'advanced',
    PER_MODE = 'totals', SEASON_TYPE = 'regular'. The first three are echoed
    request parameters; SEASON_TYPE survives as season_type_name because it
    is the one that will stop being constant when postseason data lands.

    No variant twins on this table. The TEAM__ payload dlt flattened into
    every row is stripped to its key.
*/

with source as (

    select * from {{ source('wnba_raw', 'team_season_advanced') }}

),

renamed as (

    select
        -- grain: team x season
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season']) }}
                                                            as team_season_advanced_key,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        season,
        {{ wnba_season_type_name('season_type') }}           as season_type_name,

        -- ---------------------------------------------------------------
        -- record and playing time
        -- ---------------------------------------------------------------
        stats__gp                                           as games_played,
        stats__w                                            as wins,
        stats__l                                            as losses,
        stats__w_pct                                        as win_pct,
        stats__min                                          as minutes_played,

        -- ---------------------------------------------------------------
        -- shooting efficiency
        -- ---------------------------------------------------------------
        stats__efg_pct                                      as effective_field_goal_pct,
        stats__ts_pct                                       as true_shooting_pct,

        -- ---------------------------------------------------------------
        -- ratings. The e_* family is the model-estimated version of the
        -- measured one beside it.
        -- ---------------------------------------------------------------
        stats__off_rating                                   as offensive_rating,
        stats__def_rating                                   as defensive_rating,
        stats__net_rating                                   as net_rating,
        stats__e_off_rating                                 as estimated_offensive_rating,
        stats__e_def_rating                                 as estimated_defensive_rating,
        stats__e_net_rating                                 as estimated_net_rating,
        stats__pie                                          as pie,

        -- ---------------------------------------------------------------
        -- pace and possessions
        -- ---------------------------------------------------------------
        stats__pace                                         as pace,
        stats__pace_per40                                   as pace_per40,
        stats__e_pace                                       as estimated_pace,
        stats__poss                                         as possessions,

        -- ---------------------------------------------------------------
        -- playmaking, ball security and rebounding rates
        -- ---------------------------------------------------------------
        stats__ast_pct                                      as assist_pct,
        stats__ast_ratio                                    as assist_ratio,
        stats__ast_to                                       as assist_to_turnover,
        stats__tm_tov_pct                                   as team_turnover_pct,
        stats__reb_pct                                      as rebound_pct,
        stats__oreb_pct                                     as offensive_rebound_pct,
        stats__dreb_pct                                     as defensive_rebound_pct

    from source

)

select * from renamed
