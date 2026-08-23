/*
    Every game on dim_game appears on the slate exactly as many times as it has
    closing lines, and at least once.

    The slate fans out per vendor and keeps one vendor-NULL row when no line
    exists. If the fan-out ever duplicated a game (a join that is not 1:1 on
    game_key, a forecast with two rows) or dropped one (an inner join where a
    left join belongs), the board would show a wrong count of games with no
    error anywhere else. This pins both directions of the reconciliation back
    to CORE.
*/

with expected as (

    select
        g.game_key,
        greatest(1, count(o.game_vendor_odds_key))      as expected_rows
    from {{ ref('dim_game') }} g
    left join {{ ref('fact_game_betting_odds_closing') }} o
        on o.game_key = g.game_key
    group by 1

),

actual as (

    select
        game_key,
        count(*)                                        as actual_rows
    from {{ ref('app_game_slate') }}
    group by 1

)

select
    e.game_key,
    e.expected_rows,
    coalesce(a.actual_rows, 0)                          as actual_rows
from expected e
left join actual a
    on a.game_key = e.game_key
where coalesce(a.actual_rows, 0) <> e.expected_rows
