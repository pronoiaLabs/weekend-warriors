/*
    Cross-check the two independent paths to a team's season record.

    fact_wnba_team_season carries the league's official standings. fact_wnba_team_game
    carries every individual game. Aggregating the latter must reproduce the
    former -- but only after filtering to season_type_name = 'Regular Season',
    because fact_wnba_team_game also holds preseason, postseason and All-Star games
    while standings are regular season only.

    This is the highest-value test on the WNBA side. It exercises the unpivot,
    the win/loss derivation, the four-way season_type classification and the
    standings record parse all at once, against a completely separate source
    table. A silent error in any of them shows up here.

    ONE STRUCTURAL DIFFERENCE FROM THE NFL VERSION, AND IT DRIVES EVERYTHING
    BELOW. The NFL standings are final, so that test asserts exact equality.
    The WNBA 2026 standings are mid-season: the endpoint was read once, at
    2026-08-08 23:59 UTC, while the game log keeps loading daily. So the log
    legitimately runs AHEAD of the standings and exact equality would fail
    every day. What is asserted instead is the shape of that gap.

    WHAT THE GAP LOOKS LIKE TODAY, measured read-only before this test was
    written. Across the 15 teams in the 2026 season the log leads the standings
    by 3 wins and 3 losses in total. Per team the lead is at most 1 win and at
    most 2 losses, and it is NEVER negative -- the standings are never ahead.
    The three games involved were identified individually:

      * 24989 and 24990, both played on 2026-08-08, a few hours before the
        standings snapshot was taken. The provider's standings endpoint had not
        picked them up yet. This is ordinary lag and it clears on the next load.
      * 24896, played 2026-06-30, team 1 beating team 8 at home. It has a full
        box score and is unambiguously a played game, and the standings
        snapshot simply omits it. That is a provider inconsistency, not a lag,
        and it is why the per-team tolerance is 2 rather than 1.

    Localised with the home and away split records, which is what makes the
    identification possible at all: team 1's missing win is a HOME win and team
    8's two missing losses are AWAY losses. That is also why the splits are
    checked here and not only the totals -- they are this fact's equivalent of
    the points_for / points_against check in the NFL version, which catches a
    home/away swap that a win-count-only test would miss. A swap preserves
    every team's total wins and moves them between the two split columns.

    THE TOLERANCE, AND WHY 2. One day of lag can cost a team at most one game,
    since no WNBA team plays twice in a day, and the single known provider
    omission costs one more. 2 is therefore the structural bound rather than a
    number picked to make today pass. It is an upper bound and not an exact
    assertion because the gap shrinks to zero on the load after the season ends.

    WHY A TOLERANCE ALONE IS NOT ENOUGH. A classification bug -- preseason or
    All-Star games leaking into 'Regular Season' -- adds games to many teams at
    once, and each leaked game adds one win to one team and one loss to
    another. A generous per-team tolerance could absorb that. So the league-wide
    BALANCE is asserted exactly alongside it: every game the log holds and the
    standings do not contributes exactly one win and exactly one loss, so the
    total win lead must equal the total loss lead. That identity is structural
    in fact_wnba_team_game, which unpivots both sides of a game together, and it
    fails if the unpivot loses a side, if win/loss derivation is asymmetric, or
    if a leaked game lands with only one participant in the standings.

    Seasons are restricted to those present in fact_wnba_team_game. fact_wnba_team_season
    spans 2008-2026 and the game log is 2026 only, so 220 of its 235 rows have
    nothing to reconcile against and are correctly out of scope. That
    restriction is a semi-join and not a filter on a literal year, so the test
    widens itself the moment older games are backfilled.
*/

{% set max_team_game_lead = 2 %}

with seasons_with_games as (

    -- scope: only seasons the game log actually covers
    select distinct season from {{ ref('fact_wnba_team_game') }}

),

from_games as (

    select
        team_id,
        season,
        sum(win_count)                                  as wins,
        sum(loss_count)                                 as losses,
        sum(case when is_home     then win_count  end)  as home_wins,
        sum(case when is_home     then loss_count end)  as home_losses,
        sum(case when not is_home then win_count  end)  as away_wins,
        sum(case when not is_home then loss_count end)  as away_losses
    from {{ ref('fact_wnba_team_game') }}
    where season_type_name = 'Regular Season'   -- to match standings
    group by team_id, season

),

from_standings as (

    select
        s.team_id,
        s.season,
        s.wins,
        s.losses,
        s.home_wins,
        s.home_losses,
        s.away_wins,
        s.away_losses
    from {{ ref('fact_wnba_team_season') }} s
    inner join seasons_with_games w
        on s.season = w.season

),

leads as (

    -- how far the game log runs ahead of the standings, per team and split.
    -- Positive is expected; negative means the standings claim a game the log
    -- does not have, which is never legitimate.
    select
        coalesce(g.team_id, s.team_id)              as team_id,
        coalesce(g.season, s.season)                as season,
        s.team_id                                   as standings_team_id,
        g.team_id                                   as games_team_id,
        s.wins                                      as standings_wins,
        g.wins                                      as game_derived_wins,
        s.losses                                    as standings_losses,
        g.losses                                    as game_derived_losses,
        g.wins        - s.wins                      as win_lead,
        g.losses      - s.losses                    as loss_lead,
        g.home_wins   - s.home_wins                 as home_win_lead,
        g.home_losses - s.home_losses               as home_loss_lead,
        g.away_wins   - s.away_wins                 as away_win_lead,
        g.away_losses - s.away_losses               as away_loss_lead
    from from_standings s
    full outer join from_games g
        on  s.team_id = g.team_id
       and  s.season  = g.season

),

per_team_failures as (

    select
        case
            when standings_team_id is null then 'team_season_only_in_games'
            when games_team_id is null     then 'team_season_only_in_standings'
            when least(win_lead, loss_lead, home_win_lead, home_loss_lead,
                       away_win_lead, away_loss_lead) < 0
                then 'standings_ahead_of_game_log'
            else 'lead_exceeds_tolerance'
        end                                         as issue,
        team_id,
        season,
        standings_wins,
        game_derived_wins,
        standings_losses,
        game_derived_losses,
        win_lead,
        loss_lead
    from leads
    where standings_team_id is null                       -- only in the game log
       or games_team_id is null                           -- only in standings
       -- the standings must never lead the game log, on any split
       or least(win_lead, loss_lead, home_win_lead, home_loss_lead,
                away_win_lead, away_loss_lead) < 0
       -- and the game log must not lead it by more than the documented bound
       or greatest(win_lead, loss_lead, home_win_lead, home_loss_lead,
                   away_win_lead, away_loss_lead) > {{ max_team_game_lead }}

),

balance_failure as (

    -- Every game the log holds and the standings do not contributes exactly
    -- one win and one loss league-wide. If the two totals differ, a game is
    -- reaching only one of its two participants.
    select
        'league_win_and_loss_leads_unbalanced'      as issue,
        null                                        as team_id,
        null                                        as season,
        null                                        as standings_wins,
        null                                        as game_derived_wins,
        null                                        as standings_losses,
        null                                        as game_derived_losses,
        sum(win_lead)                               as win_lead,
        sum(loss_lead)                              as loss_lead
    from leads
    having sum(win_lead) <> sum(loss_lead)

)

select * from per_team_failures
union all
select * from balance_failure
