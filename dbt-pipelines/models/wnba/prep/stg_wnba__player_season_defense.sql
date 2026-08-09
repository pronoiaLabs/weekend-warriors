{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_season_defense -- season defensive totals, rates and
    win shares, plus what the opponent scored by origin.

    Grain: player x season. 224 rows, 2026 regular season only. Same 224
    players as the other four player_season_* models.

    TWO REBOUND COLUMNS THAT LOOK LIKE ONE. The source carries both
    DREB_PCT and PCT_DREB and they are different measures, not a duplicate:
    DREB_PCT is the standard defensive rebound rate against available
    rebounds (defensive_rebound_pct here) and PCT_DREB is this player's share
    of her team's defensive rebounds (rebounds_defensive_pct here). The
    naming follows stg_wnba__player_season_advanced and
    stg_wnba__player_season_usage respectively, so the same concept carries
    the same name across the family. Same pattern for blocks and steals,
    where only the team-share version (PCT_BLK / PCT_STL) exists.

    THE RANK COLUMNS ARE DROPPED. 18 of the 68 source columns are *_RANK.
    They are league ranks computed over the full population, so they are
    wrong the moment a query filters, and ordering by the metric re-derives
    them correctly at any scope. See stg_wnba__player_season_advanced for the
    full argument.

    FOUR CONSTANT COLUMNS ARE DROPPED. Verified with SELECT DISTINCT over all
    224 rows: SCOPE = 'general', MEASURE_TYPE = 'defense',
    PER_MODE = 'totals', SEASON_TYPE = 'regular'. The first three are echoed
    request parameters; SEASON_TYPE survives as season_type_name because it
    is the one that will stop being constant when postseason data lands.

    This is the only player_season_* table with no TEAM_COUNT column, so a
    multi-team player cannot be identified from this model alone.

    No variant twins on this table. The TEAM__ / PLAYER__ payloads dlt
    flattened into every row are stripped to their keys.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_season_defense') }}

),

renamed as (

    select
        -- grain: player x season
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season']) }}
                                                            as player_season_defense_key,
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
        stats__min                                          as minutes_played,
        stats__age                                          as age,

        -- ---------------------------------------------------------------
        -- defensive counting stats
        -- ---------------------------------------------------------------
        stats__dreb                                         as defensive_rebounds,
        stats__stl                                          as steals,
        stats__blk                                          as blocks,

        -- ---------------------------------------------------------------
        -- rates. See the header on the two rebound denominators.
        -- ---------------------------------------------------------------
        stats__dreb_pct                                     as defensive_rebound_pct,
        stats__pct_dreb                                     as rebounds_defensive_pct,
        stats__pct_stl                                      as steals_pct,
        stats__pct_blk                                      as blocks_pct,

        -- ---------------------------------------------------------------
        -- ratings and win shares
        -- ---------------------------------------------------------------
        stats__def_rating                                   as defensive_rating,
        stats__def_ws                                       as defensive_win_shares,
        stats__def_ws_raw                                   as defensive_win_shares_raw,

        -- ---------------------------------------------------------------
        -- what the opponent scored, by origin
        -- ---------------------------------------------------------------
        stats__opp_pts_paint                                as opp_points_paint,
        stats__opp_pts_fb                                   as opp_points_fast_break,
        stats__opp_pts_off_tov                              as opp_points_off_turnovers,
        stats__opp_pts_2_nd_chance                          as opp_points_second_chance

    from source

)

select * from renamed
