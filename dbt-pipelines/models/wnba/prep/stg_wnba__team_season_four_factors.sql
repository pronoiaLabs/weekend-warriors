{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__team_season_four_factors -- the four factors of winning
    basketball (shooting, turnovers, rebounding, free throws) for the team
    and, symmetrically, for its opponents.

    Grain: team x season. 15 rows, 2026 regular season only.

    Each factor comes as a pair: the team's own rate and the opp_ rate it
    allowed. Nothing here is derivable from the other three tables in the
    team_season_* family, because the opponent-allowed rates are what make
    the four factors a defensive measure as well as an offensive one.

    Column names match stg_wnba__team_game_advanced's four-factors block, so
    a season row and the games that make it up read the same way.

    THE RANK COLUMNS ARE DROPPED. 13 of the 40 source columns are *_RANK.
    A rank is only valid over the population it was computed on and survives
    any filter a query applies, so it lies as soon as the scope narrows.
    Ordering by the metric re-derives it correctly, and over 15 teams that
    is trivial to do.

    FOUR CONSTANT COLUMNS ARE DROPPED. Verified with SELECT DISTINCT over all
    15 rows: SCOPE = 'general', MEASURE_TYPE = 'four_factors',
    PER_MODE = 'totals', SEASON_TYPE = 'regular'. The first three are echoed
    request parameters; SEASON_TYPE survives as season_type_name because it
    is the one that will stop being constant when postseason data lands.

    No variant twins on this table. The TEAM__ payload dlt flattened into
    every row is stripped to its key.
*/

with source as (

    select * from {{ source('wnba_raw', 'team_season_four_factors') }}

),

renamed as (

    select
        -- grain: team x season
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season']) }}
                                                            as team_season_four_factors_key,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        season,
        {{ wnba_season_type_name('season_type') }}           as season_type_name,

        -- ---------------------------------------------------------------
        -- record and playing time
        -- ---------------------------------------------------------------
        stats__gp                                           as games_played,
        stats__w                                            as wins,
        stats__l                                            as losses,
        stats__w_pct                                        as win_pct,
        stats__min                                          as minutes_played,

        -- ---------------------------------------------------------------
        -- the four factors, this team
        -- ---------------------------------------------------------------
        stats__efg_pct                                      as effective_field_goal_pct,
        stats__tm_tov_pct                                   as team_turnover_pct,
        stats__oreb_pct                                     as offensive_rebound_pct,
        stats__fta_rate                                     as free_throw_attempt_rate,

        -- ---------------------------------------------------------------
        -- the four factors, allowed
        -- ---------------------------------------------------------------
        stats__opp_efg_pct                                  as opp_effective_field_goal_pct,
        stats__opp_tov_pct                                  as opp_team_turnover_pct,
        stats__opp_oreb_pct                                 as opp_offensive_rebound_pct,
        stats__opp_fta_rate                                 as opp_free_throw_attempt_rate

    from source

)

select * from renamed
