{#
    assert_player_bridge_match_rate -- the bridge places at least a floor
    share of each vendor's players.

    Rate = bridged rows / (bridged + unmatched) per vendor, read from the two
    tables SP_PLAYER_BRIDGE writes. The floor is a var so it can be raised as
    the match rules improve: measured deterministic-only rates were 78%
    (BallDontLie) and 79% (Sleeper) before the search and AI tiers existed.

    A drop below the floor means the vendor changed a vocabulary (a new team
    code, a new position code) or the search service is broken, and the
    unmatched ledger says which.

    Override: --vars '{nfl_player_bridge_match_floor: 0.9}'
#}

{% set floor = var('nfl_player_bridge_match_floor', 0.75) %}

with bridged as (

    select vendor, count(*) as n
    from {{ nfl_player_bridge_fqn() }}
    group by vendor

),

open as (

    select vendor, count(*) as n
    from {{ nfl_player_bridge_fqn('PLAYER_BRIDGE_UNMATCHED') }}
    group by vendor

),

rates as (

    select
        coalesce(b.vendor, o.vendor)                    as vendor,
        coalesce(b.n, 0)                                as bridged,
        coalesce(b.n, 0) + coalesce(o.n, 0)             as total
    from bridged b
    full outer join open o
        on o.vendor = b.vendor

)

select
    vendor,
    bridged,
    total,
    bridged / nullif(total, 0)                          as match_rate
from rates
where bridged / nullif(total, 0) < {{ floor }}
