{{ config(severity='warn') }}

-- depends_on: {{ ref('bridge_player_ids') }}
-- (the FQN below bypasses ref(), so without this line dbt schedules the test
--  before the model whose pre_hook creates the table -- it raced and failed
--  on the first build into the fresh DIM schema at the cutover.)

{#
    assert_player_bridge_is_one_to_one -- which nflverse players are claimed by
    two ids of the same vendor.

    The procedure's tiers pick at most one gsis_id per vendor row, but nothing
    stops two vendor rows from landing on the same nflverse player, and some
    SHOULD: BallDontLie carries genuine duplicates (two ids for Vinny
    Testaverde, two for Chuck Wiley, measured 2026-08-23), and both ids really
    are that person. bridge_player_ids keeps its grain by ranking the claims
    and taking one, so this is a warning, not a failure: the list to read when
    the count moves, because a jump means the AI tier started saying yes to
    strangers again (the name gate in confirm.py exists because it did).
#}

select
    vendor,
    gsis_id,
    count(*)                                            as claims,
    listagg(vendor_player_id || ':' || match_method, ', ')
        within group (order by vendor_player_id)        as claimants
from {{ nfl_player_bridge_fqn() }}
group by vendor, gsis_id
having count(*) > 1
