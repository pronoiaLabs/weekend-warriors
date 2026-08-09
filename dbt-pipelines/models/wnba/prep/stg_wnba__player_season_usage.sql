{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_season_usage -- what share of her team's activity a
    player accounted for over the season, one column per counting stat.

    Grain: player x season. 224 rows, 2026 regular season only. Same 224
    players as the other four player_season_* models.

    Read these against stg_wnba__player_season_scoring, which uses the same
    _pct suffix for a different denominator. Here the denominator is the
    TEAM's total; there it is the PLAYER's own. rebounds_offensive_pct on
    this model is "her share of the team's offensive rebounds";
    offensive_rebound_pct on stg_wnba__player_season_advanced is the standard
    rebound rate against available rebounds. They are not interchangeable.

    THE RANK COLUMNS ARE DROPPED. 23 of the 78 source columns are *_RANK.
    They are league ranks computed over the full population, so they are
    wrong the moment a query filters, and ordering by the metric re-derives
    them correctly at any scope. See stg_wnba__player_season_advanced for the
    full argument.

    FOUR CONSTANT COLUMNS ARE DROPPED. Verified with SELECT DISTINCT over all
    224 rows: SCOPE = 'general', MEASURE_TYPE = 'usage', PER_MODE = 'totals',
    SEASON_TYPE = 'regular'. The first three are echoed request parameters;
    SEASON_TYPE survives as season_type_name because it is the one that will
    stop being constant when postseason data lands.

    No variant twins on this table. The TEAM__ / PLAYER__ payloads dlt
    flattened into every row are stripped to their keys.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_season_usage') }}

),

renamed as (

    select
        -- grain: player x season
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season']) }}
                                                            as player_season_usage_key,
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
        -- overall usage rate. This one is the standard possession-based
        -- measure, not a share of a team total like the rest of the model.
        -- ---------------------------------------------------------------
        stats__usg_pct                                      as usage_pct,

        -- ---------------------------------------------------------------
        -- share of the team's scoring and shooting
        -- ---------------------------------------------------------------
        stats__pct_pts                                      as points_pct,
        stats__pct_fgm                                      as field_goals_made_pct,
        stats__pct_fga                                      as field_goals_attempted_pct,
        stats__pct_fg3_m                                    as three_pointers_made_pct,
        stats__pct_fg3_a                                    as three_pointers_attempted_pct,
        stats__pct_ftm                                      as free_throws_made_pct,
        stats__pct_fta                                      as free_throws_attempted_pct,

        -- ---------------------------------------------------------------
        -- share of the team's playmaking, rebounding and defence
        -- ---------------------------------------------------------------
        stats__pct_ast                                      as assists_pct,
        stats__pct_tov                                      as turnovers_pct,
        stats__pct_reb                                      as rebounds_total_pct,
        stats__pct_oreb                                     as rebounds_offensive_pct,
        stats__pct_dreb                                     as rebounds_defensive_pct,
        stats__pct_stl                                      as steals_pct,
        stats__pct_blk                                      as blocks_pct,
        stats__pct_blka                                     as blocks_allowed_pct,
        stats__pct_pf                                       as personal_fouls_pct,
        stats__pct_pfd                                      as personal_fouls_drawn_pct

    from source

)

select * from renamed
