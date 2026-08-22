/*
    feat_team_game_rolling is the dim_game slate unpivoted: exactly two
    rows per game, one per side.
*/

with expected as (

    select count(*) * 2 as n from {{ ref('dim_game') }}

),

actual as (

    select count(*) as n from {{ ref('feat_team_game_rolling') }}

)

select
    e.n as expected_rows,
    a.n as actual_rows
from expected e
cross join actual a
where e.n <> a.n
