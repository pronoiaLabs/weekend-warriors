/*
    fact_team_game_defense must be the exact 1:1 mirror of
    fact_team_game_offense.

    Three things are asserted, each against the offense fact rather than
    against raw, because the defense fact is DEFINED as a re-reading of the
    offense fact and any drift between them is a bug in the self-join:

      * coverage: every team_game_key exists in both facts and in neither
        alone (full outer join, unmatched on either side fails);
      * the result mirrors: this row's points_allowed is the opponent's
        points_scored;
      * the allowed block mirrors: opp_total_yards, opp_turnovers and
        has_opp_box_score equal the opponent row's total_yards, turnovers
        and has_box_score. Three representative columns; the rest ride the
        same join and the same aliasing pattern.

    equal_null so a NULL box score on both sides (the 4 gap rows) agrees
    instead of vanishing from the comparison.
*/

with offense as (

    select
        team_game_key,
        game_key,
        team_key,
        opponent_team_key,
        points_scored,
        total_yards,
        turnovers,
        success_plays,
        has_box_score
    from {{ ref('fact_team_game_offense') }}

),

defense as (

    select
        team_game_key,
        game_id,
        team_id,
        points_allowed,
        opp_total_yards,
        opp_turnovers,
        def_success_plays,
        has_opp_box_score
    from {{ ref('fact_team_game_defense') }}

)

select
    coalesce(d.team_game_key, own.team_game_key)    as team_game_key,
    d.game_id,
    d.team_id,
    d.points_allowed,
    opp.points_scored                               as opponent_points_scored,
    d.opp_total_yards,
    opp.total_yards                                 as opponent_total_yards,
    d.opp_turnovers,
    opp.turnovers                                   as opponent_turnovers,
    d.has_opp_box_score,
    opp.has_box_score                               as opponent_has_box_score
from defense d
full outer join offense own
    on d.team_game_key = own.team_game_key
left join offense opp
    on  own.game_key = opp.game_key
    and own.opponent_team_key = opp.team_key
where d.team_game_key is null                                       -- in offense, missing from defense
   or own.team_game_key is null                                     -- in defense, not in offense
   or not equal_null(d.points_allowed, opp.points_scored)           -- result does not mirror
   or not equal_null(d.opp_total_yards, opp.total_yards)            -- allowed block does not mirror
   or not equal_null(d.opp_turnovers, opp.turnovers)
   or not equal_null(d.def_success_plays, opp.success_plays)         -- epa allowed block does not mirror
   or not equal_null(d.has_opp_box_score, opp.has_box_score)
