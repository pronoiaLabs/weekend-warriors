-- The facts must cover the raw source exactly: every completed raw game is
-- in fact_ncaaf_team_game (twice), no scheduled game leaked in, and the
-- player-game fact holds exactly the raw stat rows.
--
-- This is the empty-array-trap guard at the modelling layer: a mis-scoped
-- upstream load reports clean success, so coverage is asserted by count,
-- never by exit code.

with raw_games as (

    select count(*) as n
    from {{ source('ncaaf_raw', 'games') }}
    where status = 'post'

),

fact_team_games as (

    select count(distinct game_id) as n, count(*) as rows_total
    from {{ ref('fact_ncaaf_team_game') }}

),

raw_player_stats as (

    select count(*) as n
    from {{ source('ncaaf_raw', 'player_stats') }}

),

fact_player_games as (

    select count(*) as n
    from {{ ref('fact_ncaaf_player_game') }}

)

select
    r.n              as raw_completed_games,
    f.n              as fact_games,
    f.rows_total     as fact_team_game_rows,
    rp.n             as raw_player_stat_rows,
    fp.n             as fact_player_game_rows
from raw_games r
cross join fact_team_games f
cross join raw_player_stats rp
cross join fact_player_games fp
where f.n <> r.n
   or f.rows_total <> 2 * r.n
   or fp.n <> rp.n
