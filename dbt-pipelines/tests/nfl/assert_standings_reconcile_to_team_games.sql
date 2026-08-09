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

    Standings seasons are restricted to seasons with at least one completed
    REGULAR-SEASON game in fact_team_game, via a semi-join rather than a
    literal year list. The regular-season scope matters: a new season enters
    the fact through completed preseason games weeks before its first
    regular-season game, and a standings snapshot for that season (32 teams
    of 0-0 records) would otherwise have nothing to reconcile against.
    Known follow-up, deliberately out of scope: once current-season
    regular-season games start completing while the standings snapshot lags
    a load behind, this test needs the WNBA version's tolerance rework
    (see assert_wnba_standings_reconcile_to_team_games).
*/

with seasons_with_regular_season_games as (

    select distinct season
    from {{ ref('fact_team_game') }}
    where season_type = 2

),

from_games as (

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
        s.team_id,
        s.season,
        s.wins,
        s.losses,
        s.ties,
        s.points_for,
        s.points_against
    from {{ ref('fact_team_season') }} s
    inner join seasons_with_regular_season_games w
        on s.season = w.season

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
