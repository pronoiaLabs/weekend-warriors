{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_season_advanced -- season-level efficiency and rate stats.

    Grain: player x season. 224 rows, 2026 regular season only.

    THE RANK COLUMNS ARE DROPPED. 35 of the 105 source columns are *_RANK,
    a precomputed league rank for the metric beside them. They are dropped
    for one reason: a rank is only valid over the population it was computed
    on, and every downstream question filters that population (by team, by
    minutes played, by position). A stored rank survives the filter and lies.
    Ordering by the metric re-derives the rank correctly at any scope, so
    nothing is lost.

    FOUR CONSTANT COLUMNS ARE DROPPED. Verified with SELECT DISTINCT over all
    224 rows: SCOPE = 'general', MEASURE_TYPE = 'advanced',
    PER_MODE = 'totals', and SEASON_TYPE = 'regular'. The first three are
    request parameters echoed back by the API and carry no information at
    this grain. SEASON_TYPE is kept, as season_type_name, because it is the
    one that will stop being constant when postseason data lands.

    On the surrogate key: season_type is deliberately NOT in it, matching the
    declared player x season grain. If postseason rows ever arrive the unique
    test on player_season_advanced_key fails, which is the signal to widen
    the grain rather than a bug to work around.

    Variant twins: STATS__MIN. The TEAM__ / PLAYER__ payloads dlt flattened
    into every row are stripped to their keys.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_season_advanced') }}

),

renamed as (

    select
        -- grain: player x season
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season']) }}
                                                            as player_season_advanced_key,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}
                                                            as player_key,
        player__id                                          as player_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        season,
        {{ wnba_season_type_name('season_type') }}           as season_type_name,

        -- ---------------------------------------------------------------
        -- playing time and record
        -- ---------------------------------------------------------------
        stats__gp                                           as games_played,
        stats__w                                            as wins,
        stats__l                                            as losses,
        stats__w_pct                                        as win_pct,
        {{ wnba_coalesce_variant('stats__min') }}
                                                            as minutes_played,
        stats__age                                          as age,
        -- number of teams the player appeared for this season
        stats__team_count                                   as team_count,

        -- ---------------------------------------------------------------
        -- shooting volume and efficiency
        -- ---------------------------------------------------------------
        stats__fga                                          as field_goals_attempted,
        stats__fgm                                          as field_goals_made,
        stats__fga_pg                                       as field_goals_attempted_per_game,
        stats__fgm_pg                                       as field_goals_made_per_game,
        stats__fg_pct                                       as field_goal_pct,
        stats__efg_pct                                      as effective_field_goal_pct,
        stats__ts_pct                                       as true_shooting_pct,

        -- ---------------------------------------------------------------
        -- ratings. The e_* family is the model-estimated version of the
        -- measured one beside it; sp_work_* is the tracking-derived version.
        -- ---------------------------------------------------------------
        stats__off_rating                                   as offensive_rating,
        stats__def_rating                                   as defensive_rating,
        stats__net_rating                                   as net_rating,
        stats__e_off_rating                                 as estimated_offensive_rating,
        stats__e_def_rating                                 as estimated_defensive_rating,
        stats__e_net_rating                                 as estimated_net_rating,
        stats__sp_work_off_rating                           as sp_work_offensive_rating,
        stats__sp_work_def_rating                           as sp_work_defensive_rating,
        stats__sp_work_net_rating                           as sp_work_net_rating,
        stats__pie                                          as pie,

        -- ---------------------------------------------------------------
        -- pace and possessions
        -- ---------------------------------------------------------------
        stats__pace                                         as pace,
        stats__pace_per40                                   as pace_per40,
        stats__e_pace                                       as estimated_pace,
        stats__sp_work_pace                                 as sp_work_pace,
        stats__poss                                         as possessions,

        -- ---------------------------------------------------------------
        -- usage, playmaking and rebounding rates
        -- ---------------------------------------------------------------
        stats__usg_pct                                      as usage_pct,
        stats__e_usg_pct                                    as estimated_usage_pct,
        stats__ast_pct                                      as assist_pct,
        stats__ast_ratio                                    as assist_ratio,
        stats__ast_to                                       as assist_to_turnover,
        stats__tm_tov_pct                                   as team_turnover_pct,
        stats__e_tov_pct                                    as estimated_turnover_pct,
        stats__reb_pct                                      as rebound_pct,
        stats__oreb_pct                                     as offensive_rebound_pct,
        stats__dreb_pct                                     as defensive_rebound_pct

    from source

)

select * from renamed
