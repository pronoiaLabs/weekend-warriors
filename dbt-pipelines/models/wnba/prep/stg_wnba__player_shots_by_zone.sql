{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_shots_by_zone -- season shooting split by court zone.

    Grain: player x season. 223 rows, 2026 regular season only.

    KEPT WIDE ON PURPOSE. The source is pivoted, one column trio per zone
    (STATS__SHOT_ZONES__<ZONE>__{FGA,FGM,FG_PCT}), and prep stays 1:1 with
    the source. fact_wnba_player_shot_zone in core unpivots it to one row per
    player per zone, which is the shape the semantic view needs.

    Zone slug mapping, source to model. The prefix and the FG_PCT to _fg_pct
    normalization are the only changes; the zone names are already legal
    identifiers on this table, unlike the 5-foot bands in
    stg_wnba__player_shots_5ft.

        RESTRICTED_AREA        -> restricted_area_*
        IN_THE_PAINT_NON_RA    -> in_the_paint_non_ra_*
        MID_RANGE              -> mid_range_*
        LEFT_CORNER_3          -> left_corner_3_*
        RIGHT_CORNER_3         -> right_corner_3_*
        CORNER_3               -> corner_3_*
        ABOVE_THE_BREAK_3      -> above_the_break_3_*
        BACKCOURT              -> backcourt_*

    CORNER_3 IS NOT AN EIGHTH ZONE, it is LEFT_CORNER_3 + RIGHT_CORNER_3.
    Verified null-safe on all 223 rows for both FGA and FGM. Summing all
    eight zones double counts the corners. It is kept because prep does not
    edit the source, and core drops it when it unpivots.

    NULL means zero attempts, not unknown: the API omits zero-valued keys.
    The decision about how to read that belongs to core, so nothing is
    coalesced here.

    Three constants are dropped, verified with SELECT DISTINCT over all 223
    rows: DISTANCE_RANGE = 'by_zone' (it is the model name),
    PER_MODE = 'totals', SEASON_TYPE = 'regular'. SEASON_TYPE survives as
    season_type_name because it is the one that will stop being constant when
    postseason data lands. ID is a per-row load artifact and is dropped.

    No variant twins on this table, unlike the other three shot models.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_shots_by_zone') }}

),

renamed as (

    select
        -- grain: player x season
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season']) }}
                                                            as player_shots_zone_key,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}
                                                            as player_key,
        player__id                                          as player_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        season,
        {{ wnba_season_type_name('season_type') }}           as season_type_name,
        stats__age                                          as age,

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
        -- backcourt -- heaves, near zero attempts for most players
        -- ---------------------------------------------------------------
        stats__shot_zones__backcourt__fga                   as backcourt_fga,
        stats__shot_zones__backcourt__fgm                   as backcourt_fgm,
        stats__shot_zones__backcourt__fg_pct                as backcourt_fg_pct

    from source

)

select * from renamed
