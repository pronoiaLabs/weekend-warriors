/*
    The last pregame snapshot per game and book is the closing line: the
    is_closing row of fact_game_betting_odds_snapshot carries the same spread
    and total as fact_game_betting_odds_closing, and every closing row has one.
*/

select
    c.game_vendor_odds_key,
    c.home_spread                                       as closing_home_spread,
    s.home_spread                                       as snapshot_home_spread,
    c.total_line                                        as closing_total_line,
    s.total_line                                        as snapshot_total_line
from {{ ref('fact_game_betting_odds_closing') }} c
left join {{ ref('fact_game_betting_odds_snapshot') }} s
    on s.game_vendor_odds_key = c.game_vendor_odds_key
   and s.is_closing
where s.game_vendor_odds_key is null
   or c.home_spread is distinct from s.home_spread
   or c.total_line is distinct from s.total_line
