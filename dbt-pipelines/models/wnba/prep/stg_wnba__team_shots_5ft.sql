{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__team_shots_5ft -- season team shooting split by 5-foot distance
    band. The same shots as stg_wnba__team_shots_by_zone, cut by distance
    from the basket instead of by court region.

    Grain: team x season. 15 rows, 2026 regular season only.

    KEPT WIDE ON PURPOSE: the source is pivoted one column trio per band and
    prep stays 1:1 with it. core unpivots to one row per team per band.

    BAND SLUG MAPPING, identical to stg_wnba__player_shots_5ft so the two
    unpivot into the same vocabulary. Every band except the first starts with
    a digit upstream, so dlt prefixed each with an underscore
    (STATS__SHOT_ZONES___30_34_FT__FGA, three underscores), and a slug like
    5_9_ft is not a legal SQL identifier unquoted. The zero-padded ft_ prefix
    is legal and sorts in court order:

        LESS_THAN_5_FT  -> ft_00_04_*      (0 to 4 feet)
        _5_9_FT         -> ft_05_09_*
        _10_14_FT       -> ft_10_14_*
        _15_19_FT       -> ft_15_19_*
        _20_24_FT       -> ft_20_24_*
        _25_29_FT       -> ft_25_29_*
        _30_34_FT       -> ft_30_34_*
        _35_39_FT       -> ft_35_39_*
        _40_FT          -> ft_40_plus_*    (40 feet and out, unbounded)

    Four constants are dropped, verified with SELECT DISTINCT over all 15
    rows: MEASURE_TYPE = 'base', DISTANCE_RANGE = '5ft_range' (it is the
    model name), PER_MODE = 'totals', SEASON_TYPE = 'regular'. SEASON_TYPE
    survives as season_type_name because it is the one that will stop being
    constant when postseason data lands. ID is a per-row load artifact and is
    dropped.

    Variant twins: the 35-39 and 40-plus foot FG_PCT columns, both folded
    below. Note this is NOT the same pair as the player model, which splits
    at 30-34 and 35-39. The registry in sources.yml is per table for exactly
    this reason: the split follows whichever cells happened to land on a
    clean integer, which is a property of the data and not of the endpoint.
*/

with source as (

    select * from {{ source('wnba_raw', 'team_shots_5ft') }}

),

renamed as (

    select
        -- grain: team x season
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season']) }}
                                                            as team_shots_5ft_key,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        season,
        {{ wnba_season_type_name('season_type') }}           as season_type_name,

        -- ---------------------------------------------------------------
        -- inside the arc
        -- ---------------------------------------------------------------
        stats__shot_zones__less_than_5_ft__fga              as ft_00_04_fga,
        stats__shot_zones__less_than_5_ft__fgm              as ft_00_04_fgm,
        stats__shot_zones__less_than_5_ft__fg_pct           as ft_00_04_fg_pct,
        stats__shot_zones___5_9_ft__fga                     as ft_05_09_fga,
        stats__shot_zones___5_9_ft__fgm                     as ft_05_09_fgm,
        stats__shot_zones___5_9_ft__fg_pct                  as ft_05_09_fg_pct,
        stats__shot_zones___10_14_ft__fga                   as ft_10_14_fga,
        stats__shot_zones___10_14_ft__fgm                   as ft_10_14_fgm,
        stats__shot_zones___10_14_ft__fg_pct                as ft_10_14_fg_pct,
        stats__shot_zones___15_19_ft__fga                   as ft_15_19_fga,
        stats__shot_zones___15_19_ft__fgm                   as ft_15_19_fgm,
        stats__shot_zones___15_19_ft__fg_pct                as ft_15_19_fg_pct,

        -- ---------------------------------------------------------------
        -- around and beyond the arc
        -- ---------------------------------------------------------------
        stats__shot_zones___20_24_ft__fga                   as ft_20_24_fga,
        stats__shot_zones___20_24_ft__fgm                   as ft_20_24_fgm,
        stats__shot_zones___20_24_ft__fg_pct                as ft_20_24_fg_pct,
        stats__shot_zones___25_29_ft__fga                   as ft_25_29_fga,
        stats__shot_zones___25_29_ft__fgm                   as ft_25_29_fgm,
        stats__shot_zones___25_29_ft__fg_pct                as ft_25_29_fg_pct,
        stats__shot_zones___30_34_ft__fga                   as ft_30_34_fga,
        stats__shot_zones___30_34_ft__fgm                   as ft_30_34_fgm,
        stats__shot_zones___30_34_ft__fg_pct                as ft_30_34_fg_pct,

        -- ---------------------------------------------------------------
        -- long range, where the variant twins live
        -- ---------------------------------------------------------------
        stats__shot_zones___35_39_ft__fga                   as ft_35_39_fga,
        stats__shot_zones___35_39_ft__fgm                   as ft_35_39_fgm,
        {{ wnba_coalesce_variant('stats__shot_zones___35_39_ft__fg_pct') }}
                                                            as ft_35_39_fg_pct,
        stats__shot_zones___40_ft__fga                      as ft_40_plus_fga,
        stats__shot_zones___40_ft__fgm                      as ft_40_plus_fgm,
        {{ wnba_coalesce_variant('stats__shot_zones___40_ft__fg_pct') }}
                                                            as ft_40_plus_fg_pct

    from source

)

select * from renamed
