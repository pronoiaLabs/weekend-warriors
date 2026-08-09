{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_shots_5ft -- season shooting split by 5-foot distance
    band. The same shots as stg_wnba__player_shots_by_zone, cut by distance
    from the basket instead of by court region.

    Grain: player x season. 223 rows, 2026 regular season only.

    KEPT WIDE ON PURPOSE. The source is pivoted, one column trio per band
    (STATS__SHOT_ZONES__<BAND>__{FGA,FGM,FG_PCT}), and prep stays 1:1 with
    the source. core unpivots to one row per player per band.

    BAND SLUG MAPPING, and the reason it is not mechanical. Every band except
    the first starts with a digit upstream, so dlt prefixed each with an
    underscore (STATS__SHOT_ZONES___30_34_FT__FGA, three underscores). A slug
    like 5_9_ft is not a legal SQL identifier unquoted, and quoting every
    column here would leak into every downstream model. So the bands take a
    zero-padded ft_ prefix, which is legal, sorts in court order, and reads
    the same in every model in the family:

        LESS_THAN_5_FT  -> ft_00_04_*      (0 to 4 feet)
        _5_9_FT         -> ft_05_09_*
        _10_14_FT       -> ft_10_14_*
        _15_19_FT       -> ft_15_19_*
        _20_24_FT       -> ft_20_24_*
        _25_29_FT       -> ft_25_29_*
        _30_34_FT       -> ft_30_34_*
        _35_39_FT       -> ft_35_39_*
        _40_FT          -> ft_40_plus_*    (40 feet and out, unbounded)

    Only the last band is open ended, which is why it is _plus and not a
    range.

    NULL means zero attempts, not unknown: the API omits zero-valued keys.
    The decision about how to read that belongs to core, so nothing is
    coalesced here.

    Three constants are dropped, verified with SELECT DISTINCT over all 223
    rows: DISTANCE_RANGE = '5ft_range' (it is the model name),
    PER_MODE = 'totals', SEASON_TYPE = 'regular'. SEASON_TYPE survives as
    season_type_name because it is the one that will stop being constant when
    postseason data lands. ID is a per-row load artifact and is dropped.

    Variant twins: the 30-34 and 35-39 foot FG_PCT columns, both folded
    below. Long-range bands are where a handful of players went 1-for-1 and
    the API returned an integer where it returns a float everywhere else.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_shots_5ft') }}

),

renamed as (

    select
        -- grain: player x season
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season']) }}
                                                            as player_shots_5ft_key,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}
                                                            as player_key,
        player__id                                          as player_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        season,
        {{ wnba_season_type_name('season_type') }}           as season_type_name,
        stats__age                                          as age,

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

        -- ---------------------------------------------------------------
        -- long range, where the variant twins live
        -- ---------------------------------------------------------------
        stats__shot_zones___30_34_ft__fga                   as ft_30_34_fga,
        stats__shot_zones___30_34_ft__fgm                   as ft_30_34_fgm,
        {{ wnba_coalesce_variant('stats__shot_zones___30_34_ft__fg_pct') }}
                                                            as ft_30_34_fg_pct,
        stats__shot_zones___35_39_ft__fga                   as ft_35_39_fga,
        stats__shot_zones___35_39_ft__fgm                   as ft_35_39_fgm,
        {{ wnba_coalesce_variant('stats__shot_zones___35_39_ft__fg_pct') }}
                                                            as ft_35_39_fg_pct,
        stats__shot_zones___40_ft__fga                      as ft_40_plus_fga,
        stats__shot_zones___40_ft__fgm                      as ft_40_plus_fgm,
        stats__shot_zones___40_ft__fg_pct                   as ft_40_plus_fg_pct

    from source

)

select * from renamed
