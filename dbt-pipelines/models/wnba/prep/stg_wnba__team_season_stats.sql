{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__team_season_stats -- team per-season line, one row per team per
    season per season type. 15 rows, all 2026 regular season
    (SEASON_TYPE = 2) today: the 13 current original franchises plus the two
    2026 expansion clubs. The defunct Monarchs and Comets appear only in
    stg_wnba__standings.

    EVERY MEASURE IS A PER-GAME AVERAGE, not a season total, exactly as in
    stg_wnba__player_season_stats. pts of 90.1 is points per game across 32
    games. Multiply by games_played for totals. Percentages are on a 0-100
    scale (46.2, not 0.462).

    Three dlt variant twins are folded back with wnba_coalesce_variant: FG3A
    (2 rows integer, 13 float), OREB (2 / 13) and STL (4 / 11). All three are
    verified mutually exclusive. At 15 rows the base column alone would have
    returned two usable values out of fifteen.

    TURNOVER is renamed to turnovers to match team_stats and player_stats,
    which is the same normalisation those two models apply.
*/

with source as (

    select * from {{ source('wnba_raw', 'team_season_stats') }}

),

renamed as (

    select
        -- grain: team x season x season type
        {{ dbt_utils.generate_surrogate_key(['team__id', 'season', 'season_type']) }}
                                                                as team_season_stats_key,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}      as team_key,
        team__id                                                as team_id,

        season,
        season_type,
        {{ wnba_season_type_name('season_type') }}              as season_type_name,

        games_played,

        -- ---------------------------------------------------------------
        -- per-game averages -- see header. Not totals.
        -- ---------------------------------------------------------------

        -- shooting
        fgm,
        fga,
        fg_pct,
        fg3m,
        {{ wnba_coalesce_variant('fg3a') }}                     as fg3a,
        fg3_pct,
        ftm,
        fta,
        ft_pct,

        -- rebounding
        {{ wnba_coalesce_variant('oreb') }}                     as oreb,
        dreb,
        reb,

        -- playmaking and defence
        ast,
        {{ wnba_coalesce_variant('stl') }}                      as stl,
        blk,
        turnover                                                as turnovers,

        -- scoring
        pts

    from source

)

select * from renamed
