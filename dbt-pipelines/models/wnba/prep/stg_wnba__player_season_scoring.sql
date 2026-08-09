{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_season_scoring -- how a player's season points and shots
    were distributed: by shot value, by court origin, and by whether the
    basket was assisted.

    Grain: player x season. 224 rows, 2026 regular season only. Same 224
    players as the other four player_season_* models.

    Every metric here is a share of this player's own total, not a share of
    the team, which is what separates this table from
    stg_wnba__player_season_usage. Both sets end in _pct and neither is a
    shooting percentage.

    THE RANK COLUMNS ARE DROPPED. 23 of the 79 source columns are *_RANK.
    They are league ranks computed over the full population, so they are
    wrong the moment a query filters, and ordering by the metric re-derives
    them correctly at any scope. See stg_wnba__player_season_advanced for the
    full argument.

    FOUR CONSTANT COLUMNS ARE DROPPED. Verified with SELECT DISTINCT over all
    224 rows: SCOPE = 'general', MEASURE_TYPE = 'scoring',
    PER_MODE = 'totals', SEASON_TYPE = 'regular'. The first three are echoed
    request parameters; SEASON_TYPE survives as season_type_name because it
    is the one that will stop being constant when postseason data lands.

    Variant twins: STATS__MIN. The TEAM__ / PLAYER__ payloads dlt flattened
    into every row are stripped to their keys.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_season_scoring') }}

),

renamed as (

    select
        -- grain: player x season
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season']) }}
                                                            as player_season_scoring_key,
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
        stats__team_count                                   as team_count,

        -- ---------------------------------------------------------------
        -- shooting volume. The only true shooting percentage on this model.
        -- ---------------------------------------------------------------
        stats__fga                                          as field_goals_attempted,
        stats__fgm                                          as field_goals_made,
        stats__fg_pct                                       as field_goal_pct,

        -- ---------------------------------------------------------------
        -- share of points by shot value and by court origin
        -- ---------------------------------------------------------------
        stats__pct_pts_2_pt                                 as points_2pt_pct,
        stats__pct_pts_3_pt                                 as points_3pt_pct,
        stats__pct_pts_2_pt_mr                              as points_midrange_2pt_pct,
        stats__pct_pts_paint                                as points_paint_pct,
        stats__pct_pts_ft                                   as points_free_throw_pct,
        stats__pct_pts_fb                                   as points_fast_break_pct,
        stats__pct_pts_off_tov                              as points_off_turnovers_pct,

        -- ---------------------------------------------------------------
        -- share of attempts by shot value
        -- ---------------------------------------------------------------
        stats__pct_fga_2_pt                                 as field_goals_attempted_2pt_pct,
        stats__pct_fga_3_pt                                 as field_goals_attempted_3pt_pct,

        -- ---------------------------------------------------------------
        -- share of made baskets that were created by someone else.
        -- assisted and unassisted are complements within each shot value.
        -- ---------------------------------------------------------------
        stats__pct_ast_2_pm                                 as assisted_2pt_pct,
        stats__pct_ast_3_pm                                 as assisted_3pt_pct,
        stats__pct_ast_fgm                                  as assisted_fgm_pct,
        stats__pct_uast_2_pm                                as unassisted_2pt_pct,
        stats__pct_uast_3_pm                                as unassisted_3pt_pct,
        stats__pct_uast_fgm                                 as unassisted_fgm_pct

    from source

)

select * from renamed
