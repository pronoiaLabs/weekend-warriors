/*
    A closing row must have been observed strictly before kickoff. Returning
    rows means post-kickoff information leaked into a pregame market fact.
*/

select
    'game_odds' as market,
    game_id,
    null::number as player_id,
    vendor,
    null::string as prop_type,
    selected_snapshot_at,
    game_datetime
from {{ ref('fact_game_betting_odds_closing') }}
where selected_snapshot_at >= game_datetime

union all

select
    'player_prop' as market,
    game_id,
    player_id,
    vendor,
    prop_type,
    selected_snapshot_at,
    game_datetime
from {{ ref('fact_player_prop_closing') }}
where selected_snapshot_at >= game_datetime
