/*
    Cross-check the two independent paths to a team's season record.

    fact_team_season carries the league's official standings. fact_team_game
    carries every individual game. Aggregating the latter must reproduce the
    former -- but only after filtering to season_type = 2, because
    fact_team_game also holds preseason and postseason games while standings are
    regular season only.

    This is the highest-value test in the project: it exercises the unpivot, the
    win/loss/tie derivation, the season_type decode, and the standings parse all
    at once, against a completely separate source table. A silent error in any of
    them shows up here.

    Also verifies points_for / points_against, which catches a home/away swap
    that a win-count-only check would miss (a swap preserves the league-wide
    win total but not each team's points).
*/

with from_games as (

    select
        team_id,
        season,
        sum(win_count)      as wins,
        sum(loss_count)     as losses,
        sum(tie_count)      as ties,
        sum(points_scored)  as points_for,
        sum(points_allowed) as points_against
    from {{ ref('fact_team_game') }}
    where season_type = 2          -- regular season only, to match standings
    group by team_id, season

),

from_standings as (

    select
        team_id,
        season,
        wins,
        losses,
        ties,
        points_for,
        points_against
    from {{ ref('fact_team_season') }}

)

select
    coalesce(g.team_id, s.team_id)  as team_id,
    coalesce(g.season, s.season)    as season,
    s.wins                          as standings_wins,
    g.wins                          as game_derived_wins,
    s.losses                        as standings_losses,
    g.losses                        as game_derived_losses,
    s.points_for                    as standings_points_for,
    g.points_for                    as game_derived_points_for,
    s.points_against                as standings_points_against,
    g.points_against                as game_derived_points_against
from from_standings s
full outer join from_games g
    on s.team_id = g.team_id
   and s.season  = g.season
where s.team_id is null                          -- team-season only in games
   or g.team_id is null                          -- team-season only in standings
   or s.wins           <> g.wins
   or s.losses         <> g.losses
   or s.ties           <> g.ties
   or s.points_for     <> g.points_for
   or s.points_against <> g.points_against
