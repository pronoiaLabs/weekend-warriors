-- Every completed game must produce exactly two team-game rows (one per
-- side), each side's points must mirror the other's, and the pair must
-- agree on a result (a W faces an L, a T faces a T).
--
-- Catches: a broken unpivot (one side dropped), a scores swap (both sides
-- claiming the same points), and result derivation drift.

with pairs as (

    select
        game_id,
        count(*)                                            as sides,
        min(points_scored)                                  as min_scored,
        max(points_scored)                                  as max_scored,
        min(points_allowed)                                 as min_allowed,
        max(points_allowed)                                 as max_allowed,
        count_if(result = 'W')                              as wins,
        count_if(result = 'L')                              as losses,
        count_if(result = 'T')                              as ties
    from {{ ref('fact_ncaaf_team_game') }}
    group by game_id

)

select *
from pairs
where sides <> 2
   or min_scored <> min_allowed      -- one side's scored is the other's allowed
   or max_scored <> max_allowed
   or not (
        (wins = 1 and losses = 1 and ties = 0)
     or (wins = 0 and losses = 0 and ties = 2)
   )
