{{ config(materialized='table') }}

/*
    fact_trade -- every trade since 2002, one row per asset moved (the
    physical table is TRADE_ASSET). Grain: trade_id x asset; trade_id groups
    the sides, asset_number orders the pieces within it, and the surrogate
    key is minted from the pair because the file itself carries a few exact
    duplicate rows (same pick listed twice, 9 rows measured Aug 2026) that
    would otherwise collide.

    An asset is a player (pfr_id) or a draft pick (pick_season / round /
    number, conditional); asset_type says which. Player assets resolve
    pfr_id -> gsis_id -> player_key through the bridge where possible and
    are KEPT when they do not resolve -- the file reaches back far beyond
    BallDontLie's 2023 floor, so most history has gsis only, or neither.
    gave / received stay the file's team abbreviations (old franchises
    included: SD, OAK, STL); season is the league year the trade belongs to,
    trade_date the calendar date.
*/

with trades as (

    select
        *,
        row_number() over (
            partition by trade_id
            order by gave, received, pfr_id nulls last,
                     pick_season, pick_round, pick_number
        )                                               as asset_number
    from {{ ref('stg_nfl__nflverse_trades') }}

),

-- pfr_id -> gsis_id / player_key. The bridge's grain is gsis_id; the qualify
-- guards the join against a duplicate pfr claim.
players as (

    select pfr_id, gsis_id, player_key
    from {{ ref('bridge_player_ids') }}
    where pfr_id is not null
    qualify row_number() over (partition by pfr_id order by gsis_id) = 1

)

select
    {{ dbt_utils.generate_surrogate_key(['t.trade_id', 't.asset_number']) }}
                                                        as trade_asset_key,
    t.trade_id,
    t.asset_number,
    t.season,
    t.trade_date,
    t.gave,
    t.received,

    iff(t.pfr_id is not null, 'player', 'pick')         as asset_type,

    -- player assets
    t.pfr_id,
    t.pfr_name,
    p.gsis_id,
    p.player_key,

    -- pick assets
    t.pick_season,
    t.pick_round,
    t.pick_number,
    t.conditional,

    t.loaded_at
from trades t
left join players p
    on p.pfr_id = t.pfr_id
