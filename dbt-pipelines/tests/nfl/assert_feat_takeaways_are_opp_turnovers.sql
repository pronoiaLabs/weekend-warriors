/*
    takeaways on the defense fact is opp_turnovers. The FEATURES window must
    not silently switch to fumbles_recovered. Reconstruct the std takeaway
    rate's numerator from prior defense.takeaways rows.
*/

with base as (

    select
        r.team_game_key,
        r.team_key,
        r.season,
        r.game_datetime,
        r.game_key,
        r.takeaways_std,
        d.takeaways
    from {{ ref('feat_team_game_rolling') }} r
    inner join {{ ref('fact_team_game_defense') }} d
        on r.team_game_key = d.team_game_key
    where r.is_completed
      and r.season_type in (2, 3)
      and d.has_opp_box_score

),

expected as (

    select
        a.team_game_key,
        sum(b.takeaways) as expected_takeaways
    from base a
    left join base b
        on  a.team_key = b.team_key
        and a.season = b.season
        and (
            b.game_datetime < a.game_datetime
            or (b.game_datetime = a.game_datetime and b.game_key < a.game_key)
        )
    group by a.team_game_key

)

select
    a.team_game_key,
    a.takeaways_std,
    e.expected_takeaways
from base a
inner join expected e
    on a.team_game_key = e.team_game_key
where not equal_null(a.takeaways_std, e.expected_takeaways)
