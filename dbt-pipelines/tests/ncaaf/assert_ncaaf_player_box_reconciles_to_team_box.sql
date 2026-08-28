-- Player passing yards summed per team-game should reconcile to the team
-- box score's passing yards, within tolerance.
--
-- TOLERANCE, NOT EQUALITY, deliberately: the provider's
-- team totals and player lines are compiled separately upstream and small
-- disagreements are theirs, not ours. The test exists to catch systematic
-- breakage (a join dropping players, a twin fold zeroing a column), so it
-- fails only when more than 2% of team-games are off by more than 10 yards.

with player_sums as (

    select
        game_id,
        team_id,
        sum(passing_yards)                      as player_passing_yards
    from {{ ref('fact_ncaaf_player_game') }}
    group by game_id, team_id

),

team_box as (

    select game_id, team_id, passing_yards
    from {{ ref('fact_ncaaf_team_game') }}
    where has_box_score

),

compared as (

    select
        t.game_id,
        t.team_id,
        t.passing_yards                         as team_passing_yards,
        p.player_passing_yards,
        abs(coalesce(t.passing_yards, 0)
          - coalesce(p.player_passing_yards, 0)) as diff
    from team_box t
    left join player_sums p
           on t.game_id = p.game_id
          and t.team_id = p.team_id

)

select
    count(*)                                    as team_games,
    count_if(diff > 10)                         as off_by_more_than_10,
    round(count_if(diff > 10) / count(*), 4)    as share_off
from compared
having share_off > 0.02
