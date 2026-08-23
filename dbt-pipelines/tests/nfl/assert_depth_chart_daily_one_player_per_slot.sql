{#
    assert_depth_chart_daily_one_player_per_slot -- the daily chart shape
    holds after game-anchoring.

    The 2025+ snapshots are unique on (date, team, formation, position,
    slot, rank) at the source (measured: zero collisions), so after picking
    one snapshot per team-game exactly one player can occupy a slot. Only
    the daily source: the 2023-24 weekly file legitimately doubles up, which
    is why the fact's key includes the player.
#}

select
    game_key,
    team_key,
    formation,
    position,
    depth_slot,
    depth_rank,
    count(*)                                            as players_in_slot
from {{ ref('fact_depth_chart') }}
where chart_source = 'daily'
group by 1, 2, 3, 4, 5, 6
having count(*) > 1
