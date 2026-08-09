/*
    Reconcile fact_team_game back to the raw source.

    Every COMPLETED game's home and away score in NFL_PROD_DB.RAW.GAMES must
    appear on the matching team's row in the fact. This is the end-to-end check
    that the unpivot assigned the right score to the right side -- a home/away
    swap would leave row counts and totals intact but fail here.

    Both raw halves are scoped to status Final / Final/OT, mirroring the
    fact's completed-games filter: scheduled games have no fact rows by
    design, and without the scope every one of them would surface as
    "in raw, missing from fact".

    Also asserts exactly one result flag per row: a game is a win, a loss, or a
    tie, never two of them and never none.
*/

with raw_games as (

    select id as game_id, home_team__id as team_id,
           home_team_score as points_scored, visitor_team_score as points_allowed
    from {{ source('nfl_raw', 'games') }}
    where status in ('Final', 'Final/OT')

    union all

    select id as game_id, visitor_team__id as team_id,
           visitor_team_score as points_scored, home_team_score as points_allowed
    from {{ source('nfl_raw', 'games') }}
    where status in ('Final', 'Final/OT')

),

fact as (

    select game_id, team_id, points_scored, points_allowed,
           win_count + loss_count + tie_count as result_flag_total
    from {{ ref('fact_team_game') }}

)

-- full outer join so missing rows on either side surface, not just mismatches
select
    coalesce(f.game_id, r.game_id)   as game_id,
    coalesce(f.team_id, r.team_id)   as team_id,
    r.points_scored                  as raw_points_scored,
    f.points_scored                  as fact_points_scored,
    r.points_allowed                 as raw_points_allowed,
    f.points_allowed                 as fact_points_allowed,
    f.result_flag_total
from fact f
full outer join raw_games r
    on f.game_id = r.game_id
   and f.team_id = r.team_id
where f.game_id is null                              -- in raw, missing from fact
   or r.game_id is null                              -- in fact, not in raw
   or f.points_scored  <> r.points_scored             -- score misassigned
   or f.points_allowed <> r.points_allowed
   or f.result_flag_total <> 1                        -- exactly one of W/L/T
