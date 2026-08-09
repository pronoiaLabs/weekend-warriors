{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__team_shots_by_zone -- season team shooting split by court zone.

    Grain: team x season. 15 rows, 2026 regular season only.

    KEPT WIDE ON PURPOSE, same as stg_wnba__player_shots_by_zone: the source
    is pivoted one column trio per zone and prep stays 1:1 with it. core
    unpivots to one row per team per zone.

    Zone slug mapping, source to model, identical to the player model so the
    two unpivot into the same vocabulary:

        RESTRICTED_AREA        -> restricted_area_*
        IN_THE_PAINT_NON_RA    -> in_the_paint_non_ra_*
        MID_RANGE              -> mid_range_*
        LEFT_CORNER_3          -> left_corner_3_*
        RIGHT_CORNER_3         -> right_corner_3_*
        CORNER_3               -> corner_3_*
        ABOVE_THE_BREAK_3      -> above_the_break_3_*
        BACKCOURT              -> backcourt_*

    CORNER_3 IS NOT AN EIGHTH ZONE, it is LEFT_CORNER_3 + RIGHT_CORNER_3,
    verified exactly on all 15 rows. Summing all eight zones double counts
    the corners. It is kept because prep does not edit the source, and core
    drops it when it unpivots.

    Four constants are dropped, verified with SELECT DISTINCT over all 15
    rows: MEASURE_TYPE = 'base', DISTANCE_RANGE = 'by_zone' (it is the model
    name), PER_MODE = 'totals', SEASON_TYPE = 'regular'. SEASON_TYPE survives
    as season_type_name because it is the one that will stop being constant
    when postseason data lands. The player-grain sibling has no MEASURE_TYPE
    column at all, which is why that list is three long there and four here.
    ID is a per-row load artifact and is dropped.

    Variant twins: BACKCOURT FG_PCT, folded below. Backcourt attempts are
    rare enough at team level that a whole season can land on a clean integer
    rate, which is exactly the condition that splits a dlt column.
*/

with source as (

    select * from {{ source('wnba_raw', 'team_shots_by_zone') }}

),

renamed as (

    select
        -- grain: team x season
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season']) }}
                                                            as team_shots_zone_key,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        season,
        {{ wnba_season_type_name('season_type') }}           as season_type_name,

        -- ---------------------------------------------------------------
        -- inside: restricted area, then the rest of the paint
        -- ---------------------------------------------------------------
        stats__shot_zones__restricted_area__fga             as restricted_area_fga,
        stats__shot_zones__restricted_area__fgm             as restricted_area_fgm,
        stats__shot_zones__restricted_area__fg_pct          as restricted_area_fg_pct,
        stats__shot_zones__in_the_paint_non_ra__fga         as in_the_paint_non_ra_fga,
        stats__shot_zones__in_the_paint_non_ra__fgm         as in_the_paint_non_ra_fgm,
        stats__shot_zones__in_the_paint_non_ra__fg_pct      as in_the_paint_non_ra_fg_pct,

        -- ---------------------------------------------------------------
        -- mid range
        -- ---------------------------------------------------------------
        stats__shot_zones__mid_range__fga                   as mid_range_fga,
        stats__shot_zones__mid_range__fgm                   as mid_range_fgm,
        stats__shot_zones__mid_range__fg_pct                as mid_range_fg_pct,

        -- ---------------------------------------------------------------
        -- three point. corner_3 is left + right, see header.
        -- ---------------------------------------------------------------
        stats__shot_zones__left_corner_3__fga               as left_corner_3_fga,
        stats__shot_zones__left_corner_3__fgm               as left_corner_3_fgm,
        stats__shot_zones__left_corner_3__fg_pct            as left_corner_3_fg_pct,
        stats__shot_zones__right_corner_3__fga              as right_corner_3_fga,
        stats__shot_zones__right_corner_3__fgm              as right_corner_3_fgm,
        stats__shot_zones__right_corner_3__fg_pct           as right_corner_3_fg_pct,
        stats__shot_zones__corner_3__fga                    as corner_3_fga,
        stats__shot_zones__corner_3__fgm                    as corner_3_fgm,
        stats__shot_zones__corner_3__fg_pct                 as corner_3_fg_pct,
        stats__shot_zones__above_the_break_3__fga           as above_the_break_3_fga,
        stats__shot_zones__above_the_break_3__fgm           as above_the_break_3_fgm,
        stats__shot_zones__above_the_break_3__fg_pct        as above_the_break_3_fg_pct,

        -- ---------------------------------------------------------------
        -- backcourt -- heaves, a handful of attempts per team per season
        -- ---------------------------------------------------------------
        stats__shot_zones__backcourt__fga                   as backcourt_fga,
        stats__shot_zones__backcourt__fgm                   as backcourt_fgm,
        {{ wnba_coalesce_variant('stats__shot_zones__backcourt__fg_pct') }}
                                                            as backcourt_fg_pct

    from source

)

select * from renamed
