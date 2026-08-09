{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__team_stats -- team box score, one row per team per game.
    476 rows, covering 238 of the 240 completed games. The two gaps are the
    2026-08-08 games, whose box scores the load has not reached yet, so
    fact_wnba_team_game left-joins this rather than inner-joining.

    dlt flattened the full game record and the team record into every row.
    Everything but game__id and team__id is dropped here, with game_date and
    season kept as degenerate attributes so a season filter does not need a
    join back to games.

    There is no team equivalent of a DNP: every team that appears played, so
    the coalesce to 0 is unconditional, unlike stg_wnba__player_stats. All 17
    measures are populated on all 476 rows today, so the coalesce never fires;
    it is here because the API omits zero-valued keys and a future shutout
    quarter would otherwise arrive as NULL and read as unknown.

    There is no points column. The source does not carry one at team x game
    grain: team points live on stg_wnba__games as home_team_score /
    away_team_score, and fact_wnba_team_game is where the two meet.

    FG_PCT / FG3_PCT / FT_PCT come straight from the source and are NOT
    recomputed. The source is authoritative on its own rounding, and a rate
    has no meaningful zero-fill, so they are passed through untouched. They
    are on a 0-100 scale (46.2, not 0.462), which is the scale every rate in
    the WNBA set uses.

    Two columns are renamed to match player_stats, which spells the same two
    measures differently: TURNOVERS -> turnovers and FOULS -> personal_fouls.

    No variant twins in this table: DESCRIBE shows no __V_DOUBLE column and
    the sources.yml registry lists none.
*/

with source as (

    select * from {{ source('wnba_raw', 'team_stats') }}

),

renamed as (

    select
        -- grain: team x game
        {{ dbt_utils.generate_surrogate_key(['game__id', 'team__id']) }} as team_game_key,
        {{ dbt_utils.generate_surrogate_key(['game__id']) }}             as game_key,
        game__id                                                        as game_id,
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}             as team_key,
        team__id                                                        as team_id,

        -- degenerate attributes off the flattened game payload
        game__date::date                                                as game_date,
        game__season                                                    as season,

        -- ---------------------------------------------------------------
        -- shooting. Counts are 0-filled, rates are passed through.
        -- ---------------------------------------------------------------
        coalesce(fgm, 0)                                                as fgm,
        coalesce(fga, 0)                                                as fga,
        fg_pct,
        coalesce(fg3m, 0)                                               as fg3m,
        coalesce(fg3a, 0)                                               as fg3a,
        fg3_pct,
        coalesce(ftm, 0)                                                as ftm,
        coalesce(fta, 0)                                                as fta,
        ft_pct,

        -- ---------------------------------------------------------------
        -- rebounding
        -- ---------------------------------------------------------------
        coalesce(oreb, 0)                                               as oreb,
        coalesce(dreb, 0)                                               as dreb,
        coalesce(reb, 0)                                                as reb,

        -- ---------------------------------------------------------------
        -- playmaking and defence
        -- ---------------------------------------------------------------
        coalesce(ast, 0)                                                as ast,
        coalesce(stl, 0)                                                as stl,
        coalesce(blk, 0)                                                as blk,
        coalesce(turnovers, 0)                                          as turnovers,
        coalesce(fouls, 0)                                              as personal_fouls

    from source

)

select * from renamed
