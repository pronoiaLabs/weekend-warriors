{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_season_stats -- basic per-season line, one row per player
    per season per season type. 196 rows, all 2026 regular season
    (SEASON_TYPE = 2) today.

    SUBSET WARNING. This table covers 196 players. The advanced-season family
    (player_season_advanced / _misc / _scoring / _usage / _defense) covers 224,
    all five in step with each other. So this is a subset of that population,
    not the other way round, and it must NEVER be the spine of a player-season
    mart: joining the advanced tables onto it silently drops 28 players.
    Build the spine off the advanced family, or off distinct players in
    stg_wnba__player_stats, and left-join this on.

    EVERY MEASURE IS A PER-GAME AVERAGE, not a season total. pts of 26.62 is
    points per game across 29 games, and summing this column over players
    produces a number with no meaning. Multiply by games_played to get totals.
    The percentages are on a 0-100 scale (53.0, not 0.530), matching every
    other rate in the WNBA set.

    Two dlt variant twins are folded back with wnba_coalesce_variant: FG3M
    (32 rows integer, 164 float) and FG3_PCT (56 integer, 140 float). Both are
    verified mutually exclusive, so the coalesce is lossless. Reading the base
    column alone would drop the majority of each.

    Two team ids arrive on the row and they are not the same thing. TEAM__ID
    is the team this season line belongs to; PLAYER__TEAM__ID is the player's
    current team, which differs on 16 of 196 rows because the player was
    traded. TEAM__ID is the one carried here.

    season_type_name comes from wnba_season_type_name, which maps this table's
    '2' / '3' encoding and the advanced tables' 'regular' / 'playoffs' strings
    onto the same vocabulary. An unrecognised encoding resolves to NULL so it
    fails a not_null test rather than landing in a silent bucket.
*/

with source as (

    select * from {{ source('wnba_raw', 'player_season_stats') }}

),

renamed as (

    select
        -- grain: player x season x season type
        {{ dbt_utils.generate_surrogate_key(['player__id', 'season', 'season_type']) }}
                                                                as player_season_key,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}    as player_key,
        player__id                                              as player_id,

        -- the team this season line belongs to -- see header
        {{ dbt_utils.generate_surrogate_key(['team__id']) }}      as team_key,
        team__id                                                as team_id,

        season,
        season_type,
        {{ wnba_season_type_name('season_type') }}              as season_type_name,

        games_played,

        -- ---------------------------------------------------------------
        -- per-game averages -- see header. Not totals.
        -- ---------------------------------------------------------------
        min                                                     as minutes_per_game,

        -- shooting
        fgm,
        fga,
        fg_pct,
        {{ wnba_coalesce_variant('fg3m') }}                     as fg3m,
        fg3a,
        {{ wnba_coalesce_variant('fg3_pct') }}                  as fg3_pct,
        ftm,
        fta,
        ft_pct,

        -- rebounding, playmaking, defence
        reb,
        ast,
        stl,
        blk,
        turnover                                                as turnovers,

        -- scoring
        pts

    from source

)

select * from renamed
