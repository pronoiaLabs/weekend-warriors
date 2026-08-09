{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__team_season_opponent -- the full box score a team ALLOWED over
    the season, one column per opponent counting stat.

    Grain: team x season. 15 rows, 2026 regular season only.

    Read every measure as "what opponents did against this team", which is
    why they all keep an opp_ prefix even though the row is keyed on the
    defending team. PLUS_MINUS is the exception and is the defending team's
    own margin, kept unprefixed for that reason.

    This is the defensive mirror of the team box score. Team offense at the
    same grain lives in stg_wnba__team_season_stats, and the rate-based view
    of the same story is stg_wnba__team_season_four_factors.

    THE RANK COLUMNS ARE DROPPED. 26 of the 66 source columns are *_RANK, the
    highest proportion in the family. A rank is only valid over the
    population it was computed on and survives any filter a query applies,
    so it lies as soon as the scope narrows. Ordering by the metric
    re-derives it correctly, and over 15 teams that is trivial to do.

    A second trap in these particular ranks: a defensive rank is good when
    the underlying number is LOW, so the stored direction is not something a
    caller can infer from the column name. Re-deriving forces the choice to
    be explicit.

    FOUR CONSTANT COLUMNS ARE DROPPED. Verified with SELECT DISTINCT over all
    15 rows: SCOPE = 'general', MEASURE_TYPE = 'opponent',
    PER_MODE = 'totals', SEASON_TYPE = 'regular'. The first three are echoed
    request parameters; SEASON_TYPE survives as season_type_name because it
    is the one that will stop being constant when postseason data lands.

    No variant twins on this table. The TEAM__ payload dlt flattened into
    every row is stripped to its key.
*/

with source as (

    select * from {{ source('wnba_raw', 'team_season_opponent') }}

),

renamed as (

    select
        -- grain: team x season
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season']) }}
                                                            as team_season_opponent_key,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }} as team_key,
        team__id                                            as team_id,

        season,
        {{ wnba_season_type_name('season_type') }}           as season_type_name,

        -- ---------------------------------------------------------------
        -- record and playing time -- this team's, not the opponents'
        -- ---------------------------------------------------------------
        stats__gp                                           as games_played,
        stats__w                                            as wins,
        stats__l                                            as losses,
        stats__w_pct                                        as win_pct,
        stats__min                                          as minutes_played,
        stats__plus_minus                                   as plus_minus,

        -- ---------------------------------------------------------------
        -- opponent scoring and shooting
        -- ---------------------------------------------------------------
        stats__opp_pts                                      as opp_points,
        stats__opp_fgm                                      as opp_field_goals_made,
        stats__opp_fga                                      as opp_field_goals_attempted,
        stats__opp_fg_pct                                   as opp_field_goal_pct,
        stats__opp_fg3_m                                    as opp_three_pointers_made,
        stats__opp_fg3_a                                    as opp_three_pointers_attempted,
        stats__opp_fg3_pct                                  as opp_three_point_pct,
        stats__opp_ftm                                      as opp_free_throws_made,
        stats__opp_fta                                      as opp_free_throws_attempted,
        stats__opp_ft_pct                                   as opp_free_throw_pct,

        -- ---------------------------------------------------------------
        -- opponent rebounding, playmaking and defence
        -- ---------------------------------------------------------------
        stats__opp_reb                                      as opp_rebounds,
        stats__opp_oreb                                     as opp_offensive_rebounds,
        stats__opp_dreb                                     as opp_defensive_rebounds,
        stats__opp_ast                                      as opp_assists,
        stats__opp_tov                                      as opp_turnovers,
        stats__opp_stl                                      as opp_steals,
        stats__opp_blk                                      as opp_blocks,
        stats__opp_blka                                     as opp_blocks_against,
        stats__opp_pf                                       as opp_personal_fouls,
        stats__opp_pfd                                      as opp_personal_fouls_drawn

    from source

)

select * from renamed
