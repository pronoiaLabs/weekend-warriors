{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_season_misc -- season totals the basic box score omits:
    points by origin (paint, fast break, off turnovers, second chance), the
    same four for the opponent while this player was involved, plus the foul
    and block counts.

    Grain: player x season. 224 rows, 2026 regular season only. Same 224
    players as the other four player_season_* models.

    THE RANK COLUMNS ARE DROPPED. 18 of the 68 source columns are *_RANK.
    They are league ranks computed over the full population, so they are
    wrong the moment a query filters, and ordering by the metric re-derives
    them correctly at any scope. See stg_wnba__player_season_advanced for the
    full argument.

    FOUR CONSTANT COLUMNS ARE DROPPED. Verified with SELECT DISTINCT over all
    224 rows: SCOPE = 'general', MEASURE_TYPE = 'misc', PER_MODE = 'totals',
    SEASON_TYPE = 'regular'. The first three are echoed request parameters;
    SEASON_TYPE survives as season_type_name because it is the one that will
    stop being constant when postseason data lands.

    NBA_FANTASY_PTS is the source's name for a fantasy scoring total. This is
    a WNBA table, so the 'nba' is a provider artifact, not a league
    attribution, and the column lands as fantasy_points.

    No variant twins on this table. The TEAM__ / PLAYER__ payloads dlt
    flattened into every row are stripped to their keys.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_season_misc') }}

),

renamed as (

    select
        -- grain: player x season
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season']) }}
                                                            as player_season_misc_key,
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
        stats__team_count                                   as team_count,

        -- ---------------------------------------------------------------
        -- fouls and blocks
        -- ---------------------------------------------------------------
        stats__pf                                           as personal_fouls,
        stats__pfd                                          as personal_fouls_drawn,
        stats__blk                                          as blocks,
        stats__blka                                         as blocks_against,

        -- ---------------------------------------------------------------
        -- points by origin
        -- ---------------------------------------------------------------
        stats__pts_paint                                    as points_paint,
        stats__pts_fb                                       as points_fast_break,
        stats__pts_off_tov                                  as points_off_turnovers,
        stats__pts_2_nd_chance                              as points_second_chance,

        -- ---------------------------------------------------------------
        -- the same four, allowed
        -- ---------------------------------------------------------------
        stats__opp_pts_paint                                as opp_points_paint,
        stats__opp_pts_fb                                   as opp_points_fast_break,
        stats__opp_pts_off_tov                              as opp_points_off_turnovers,
        stats__opp_pts_2_nd_chance                          as opp_points_second_chance,

        -- provider's fantasy total, see header on the name
        stats__nba_fantasy_pts                              as fantasy_points

    from source

)

select * from renamed
