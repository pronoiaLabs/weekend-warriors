{#
    assert_team_game_epa_mirrors -- a team's offense IS its opponent's defense.

    fact_team_game_epa builds def_* by re-reading the same scrimmage plays
    from the defending side, so per game a team's off_epa must equal its
    opponent's def_epa and the play counts must match, to floating-point
    noise. The same construction guard as
    assert_fact_team_game_defense_mirrors_offense: if this fails, a filter
    drifted between the offense and defense CTEs.
#}

with paired as (

    select
        a.game_id,
        a.team_id,
        a.off_plays,
        a.off_epa,
        b.def_plays                                     as opp_def_plays,
        b.def_epa                                       as opp_def_epa
    from {{ ref('fact_team_game_epa') }} a
    inner join {{ ref('fact_team_game_epa') }} b
        on  b.game_id = a.game_id
        and b.team_key = a.opponent_team_key

)

select *
from paired
where off_plays != opp_def_plays
   or abs(off_epa - opp_def_epa) > 0.001
