/*
    label_* is null on unplayed games and populated on completed ones.
    Total is the representative: it is the sum of the two score labels.
*/

select
    game_key,
    is_completed,
    label_home_points,
    label_away_points,
    label_total
from {{ ref('feat_game_matchup') }}
where (is_completed and label_total is null)
   or (not is_completed and (
        label_total is not null
        or label_home_points is not null
        or label_away_points is not null
        or label_home_margin is not null
        or label_home_net_pass is not null
        or label_away_net_pass is not null
        or label_home_rush is not null
        or label_away_rush is not null
   ))
