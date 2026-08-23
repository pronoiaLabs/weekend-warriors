/*
    The prop board is fact_player_prop_closing, row for row, with the same lines.

    The board joins six things onto the prop fact; every join is meant to be
    at most one row per prop. A duplicated key would trip the unique test, but
    a dropped prop (an inner join where a left join belongs) or a line that
    drifted (a join on the wrong key) would not. Three checks in one: row
    count, every key present, and the summed line values equal.
*/

with fact_side as (

    select
        count(*)                                        as n_rows,
        sum(coalesce(line_value, 0))                    as sum_lines
    from {{ ref('fact_player_prop_closing') }}

),

board_side as (

    select
        count(*)                                        as n_rows,
        sum(coalesce(line_value, 0))                    as sum_lines
    from {{ ref('app_game_prop_board') }}

),

missing as (

    select count(*)                                     as n_missing
    from {{ ref('fact_player_prop_closing') }} p
    left join {{ ref('app_game_prop_board') }} b
        on b.game_player_vendor_prop_key = p.game_player_vendor_prop_key
    where b.game_player_vendor_prop_key is null

)

select
    f.n_rows                                            as fact_rows,
    b.n_rows                                            as board_rows,
    f.sum_lines                                         as fact_sum_lines,
    b.sum_lines                                         as board_sum_lines,
    m.n_missing
from fact_side f
cross join board_side b
cross join missing m
where f.n_rows <> b.n_rows
   or abs(f.sum_lines - b.sum_lines) > 0.01
   or m.n_missing > 0
