{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_player_season_shooting -- season player shooting, unpivoted to one row
    per shot location. Grain: player x season x zone_scheme x zone. 3,568 rows.

    223 players x 16 locations: 7 court zones plus 9 distance bands. Identical
    shape, vocabulary and rules to fact_wnba_team_season_shooting, so a player's
    shot profile and her team's read the same way and can be compared without a
    translation step.

    THE TWO SCHEMES ARE THE SAME SHOTS CUT TWO WAYS. zone_scheme is not an
    optional filter -- summing across both counts every attempt twice. Verified
    read-only: the zone total and the band total are identical for all 223
    players, to the attempt, and both equal
    stg_wnba__player_season_advanced.field_goals_attempted exactly.

    CORNER_3 IS DROPPED. The source's CORNER_3 is not an eighth zone, it is
    LEFT_CORNER_3 + RIGHT_CORNER_3, verified null-safe on all 223 rows. Prep
    keeps it because prep does not edit the source; it is removed here because
    a long table invites SUM(fga) and that sum would double count every corner
    three. left_corner_3 and right_corner_3 both survive, so a caller who wants
    the combined corner adds them.

    223 PLAYERS, NOT 224. One player in the advanced family has no shot-location
    row. That is the source's coverage, not a join loss, and it is why the
    reconciliation test compares the shot totals against the advanced fact
    where a row exists rather than asserting equal populations.

    NULL MEANS ZERO ATTEMPTS. The API omits zero-valued keys, so prep carries
    NULL where a player took no shots from a location and leaves the reading to
    core. Here fga and fgm are coalesced to 0, which is what the absence means.

    fg_pct IS NULLED WHERE THERE WERE NO ATTEMPTS. The source writes 0.0 rather
    than NULL for a location with zero attempts -- 159 of the 223 backcourt
    rows are exactly this -- and a 0.0 shooting percentage over zero shots is
    not a bad performance, it is no performance. Left alone it drags every
    AVG(fg_pct) down and makes the backcourt look like the worst-shot location
    in basketball for a reason that has nothing to do with shooting. It is
    already a 0-1 fraction and needs no conversion.
*/

with by_zone as (

    select * from {{ ref('stg_wnba__player_shots_by_zone') }}

),

by_distance as (

    select * from {{ ref('stg_wnba__player_shots_5ft') }}

),

unpivoted as (

    -- --------------------------------------------------------------------
    -- scheme 'zone': court region. 7 zones, corner_3 deliberately absent.
    -- --------------------------------------------------------------------
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'zone'                 as zone_scheme,
           'restricted_area'      as zone,
           restricted_area_fga    as fga,
           restricted_area_fgm    as fgm,
           restricted_area_fg_pct as fg_pct
    from by_zone
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'zone', 'in_the_paint_non_ra',
           in_the_paint_non_ra_fga, in_the_paint_non_ra_fgm, in_the_paint_non_ra_fg_pct
    from by_zone
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'zone', 'mid_range',
           mid_range_fga, mid_range_fgm, mid_range_fg_pct
    from by_zone
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'zone', 'left_corner_3',
           left_corner_3_fga, left_corner_3_fgm, left_corner_3_fg_pct
    from by_zone
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'zone', 'right_corner_3',
           right_corner_3_fga, right_corner_3_fgm, right_corner_3_fg_pct
    from by_zone
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'zone', 'above_the_break_3',
           above_the_break_3_fga, above_the_break_3_fgm, above_the_break_3_fg_pct
    from by_zone
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'zone', 'backcourt',
           backcourt_fga, backcourt_fgm, backcourt_fg_pct
    from by_zone

    -- --------------------------------------------------------------------
    -- scheme 'distance_5ft': feet from the basket. 9 bands, the last open
    -- ended. Slugs are zero padded so they sort in court order.
    -- --------------------------------------------------------------------
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_00_04',
           ft_00_04_fga, ft_00_04_fgm, ft_00_04_fg_pct
    from by_distance
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_05_09',
           ft_05_09_fga, ft_05_09_fgm, ft_05_09_fg_pct
    from by_distance
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_10_14',
           ft_10_14_fga, ft_10_14_fgm, ft_10_14_fg_pct
    from by_distance
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_15_19',
           ft_15_19_fga, ft_15_19_fgm, ft_15_19_fg_pct
    from by_distance
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_20_24',
           ft_20_24_fga, ft_20_24_fgm, ft_20_24_fg_pct
    from by_distance
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_25_29',
           ft_25_29_fga, ft_25_29_fgm, ft_25_29_fg_pct
    from by_distance
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_30_34',
           ft_30_34_fga, ft_30_34_fgm, ft_30_34_fg_pct
    from by_distance
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_35_39',
           ft_35_39_fga, ft_35_39_fgm, ft_35_39_fg_pct
    from by_distance
    union all
    select player_key, player_id, team_key, team_id, season, season_type_name,
           'distance_5ft', 'ft_40_plus',
           ft_40_plus_fga, ft_40_plus_fgm, ft_40_plus_fg_pct
    from by_distance

)

select
    -- keys
    {{ dbt_utils.generate_surrogate_key(['player_id', 'season', 'zone_scheme', 'zone']) }}
                                        as player_season_shooting_key,
    player_key,
    player_id,

    -- the team the shot-location endpoint attributed the season to
    team_key,
    team_id,

    season,
    season_type_name,

    -- location
    zone_scheme,
    zone,

    -- volume. NULL means no attempts -- see header.
    coalesce(fga, 0)                    as fga,
    coalesce(fgm, 0)                    as fgm,

    -- undefined over zero attempts, not zero -- see header
    case when coalesce(fga, 0) > 0 then fg_pct end
                                        as fg_pct

from unpivoted
