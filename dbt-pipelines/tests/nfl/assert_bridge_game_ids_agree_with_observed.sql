{#
    assert_bridge_game_ids_agree_with_observed -- the composed nflverse game
    id equals the one nflverse actually used, wherever both exist.

    bridge_game_ids composes an id for every game from the week and
    abbreviation rules and takes nflverse's own id from play-by-play once the
    game is played. The two must agree on every played game: a mismatch means
    a rule drifted (a relocated club, a playoff week renumbered) and the
    composed ids on future games are wrong too.
#}

select
    game_key,
    game_id,
    season,
    week,
    nflverse_game_id,
    nflverse_game_id_composed
from {{ ref('bridge_game_ids') }}
where is_nflverse_observed
  and nflverse_game_id_composed is distinct from nflverse_game_id
