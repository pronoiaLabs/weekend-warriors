/*
    feat_game_matchup is one row per dim_game game.
*/

with expected as (

    select count(*) as n from {{ ref('dim_game') }}

),

actual as (

    select count(*) as n from {{ ref('feat_game_matchup') }}

)

select
    e.n as expected_rows,
    a.n as actual_rows
from expected e
cross join actual a
where e.n <> a.n
