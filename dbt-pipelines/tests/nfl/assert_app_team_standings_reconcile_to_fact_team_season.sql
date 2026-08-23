/*
    The derived standings agree with the league's official record.

    app_team_standings ('all' split, regular season) is built by summing
    fact_team_game_offense; fact_team_season is the source's end-of-season
    snapshot. Where a season is finished (every team has a fact_team_season
    row), wins, losses and ties must match for every team. An in-progress
    season has no fact_team_season row and is not compared.
*/

select
    s.team_key,
    s.season,
    s.wins                                              as derived_wins,
    f.wins                                              as official_wins,
    s.losses                                            as derived_losses,
    f.losses                                            as official_losses,
    s.ties                                              as derived_ties,
    f.ties                                              as official_ties
from {{ ref('app_team_standings') }} s
inner join {{ ref('fact_team_season') }} f
    on f.team_key = s.team_key
   and f.season = s.season
where s.split = 'all'
  and s.season_type = 2
  and (
        s.wins <> f.wins
     or s.losses <> f.losses
     or coalesce(s.ties, 0) <> coalesce(f.ties, 0)
  )
