/*
    Cross-check the two independent paths to a team's season record.

    fact_team_season carries the league's official standings. fact_team_game_offense
    carries every individual game. Aggregating the latter must reproduce the
    former -- but only after filtering to season_type = 2, because
    fact_team_game_offense also holds preseason and postseason games while standings
    are regular season only.

    This is the highest-value test in the project: it exercises the unpivot,
    the win/loss/tie derivation, the season_type decode, and the standings
    parse all at once, against a completely separate source table. A silent
    error in any of them shows up here.

    TOLERANCE, NOT EXACT EQUALITY. Ported from
    assert_wnba_standings_reconcile_to_team_games, where the full reasoning
    lives. In season, the game log loads daily while the standings snapshot
    can trail it by a load, so the log legitimately runs AHEAD of the
    standings and exact equality would fail every day from the first
    completed regular-season game. What is asserted instead is the shape of
    the gap:

      * the standings never lead the game log, on any split or on points;
      * per team, the log leads by at most the tolerance on every win/loss/
        tie split: one day of lag costs at most one game (no NFL team plays
        twice in a day) plus one game of headroom for a provider omission,
        the WNBA precedent;
      * league-wide, the total win lead equals the total loss lead exactly
        (every missing game contributes one win and one loss; a missing tie
        adds zero to both), the total tie lead is even (a missing tie is
        exactly two tie-legs), and the total points_for lead equals the
        total points_against lead (every game's points appear once as PF
        and once as PA). These balance checks are exact, so a generous
        per-team tolerance cannot absorb a classification bug that leaks
        games into the regular season for many teams at once.

    Points leads are excluded from the per-team upper bound (one game moves
    20-50 points); their protection is the non-negativity check plus the
    league-wide PF/PA balance, which together preserve the old exact test's
    ability to catch a home/away swap (a swap preserves league-wide totals
    but not each team's splits or points).

    TWO NFL DIVERGENCES FROM THE WNBA STRUCTURE, both deliberate:

      * The games side is COALESCED TO 0 rather than failed when absent. In
        week 1, once the first completed regular-season game pulls the season
        into scope, ~30 teams have a standings row and zero completed
        regular-season games -- legitimate, and a 0-0-0 standings row against
        an empty game log passes, while a standings row claiming wins with no
        game rows correctly goes negative. The coalesce also covers the
        home/road split sums, which are NULL for a team whose only games so
        far are on the road. The WNBA 'team_season_only_in_standings' branch
        is absorbed by this coalesce and deliberately dropped. The standings
        side is NOT coalesced: a team-season only in the game log stays a
        hard failure.

      * Ties are real in the NFL, so tie leads ride through every split and
        the balance check.

    Standings seasons are restricted to seasons with at least one completed
    REGULAR-SEASON game in fact_team_game_offense, via a semi-join rather than a
    literal year list. The scoping and the tolerance solve different windows
    and both are needed: the scope keeps a new season's 32 x 0-0 standings
    snapshot out until regular-season play begins (the preseason-only
    window); the tolerance covers the in-season lag once it has.
*/

{% set max_team_game_lead = 2 %}

with seasons_with_regular_season_games as (

    select distinct season
    from {{ ref('fact_team_game_offense') }}
    where season_type = 2

),

from_games as (

    select
        team_id,
        season,
        sum(win_count)                                  as wins,
        sum(loss_count)                                 as losses,
        sum(tie_count)                                  as ties,
        sum(points_scored)                              as points_for,
        sum(points_allowed)                             as points_against,
        sum(case when is_home     then win_count  end)  as home_wins,
        sum(case when is_home     then loss_count end)  as home_losses,
        sum(case when is_home     then tie_count  end)  as home_ties,
        sum(case when not is_home then win_count  end)  as road_wins,
        sum(case when not is_home then loss_count end)  as road_losses,
        sum(case when not is_home then tie_count  end)  as road_ties
    from {{ ref('fact_team_game_offense') }}
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
        s.points_against,
        s.home_wins,
        s.home_losses,
        s.home_ties,
        s.road_wins,
        s.road_losses,
        s.road_ties
    from {{ ref('fact_team_season') }} s
    inner join seasons_with_regular_season_games w
        on s.season = w.season

),

leads as (

    -- how far the game log runs ahead of the standings, per team and split.
    -- Positive is expected in season; negative means the standings claim a
    -- game the log does not have, which is never legitimate. The games side
    -- coalesces to 0 (see header); the standings side does not.
    select
        coalesce(g.team_id, s.team_id)                   as team_id,
        coalesce(g.season, s.season)                     as season,
        s.team_id                                        as standings_team_id,
        s.wins                                           as standings_wins,
        coalesce(g.wins, 0)                              as game_derived_wins,
        s.losses                                         as standings_losses,
        coalesce(g.losses, 0)                            as game_derived_losses,
        coalesce(g.wins, 0)           - s.wins           as win_lead,
        coalesce(g.losses, 0)         - s.losses         as loss_lead,
        coalesce(g.ties, 0)           - s.ties           as tie_lead,
        coalesce(g.home_wins, 0)      - s.home_wins      as home_win_lead,
        coalesce(g.home_losses, 0)    - s.home_losses    as home_loss_lead,
        coalesce(g.home_ties, 0)      - s.home_ties      as home_tie_lead,
        coalesce(g.road_wins, 0)      - s.road_wins      as road_win_lead,
        coalesce(g.road_losses, 0)    - s.road_losses    as road_loss_lead,
        coalesce(g.road_ties, 0)      - s.road_ties      as road_tie_lead,
        coalesce(g.points_for, 0)     - s.points_for     as points_for_lead,
        coalesce(g.points_against, 0) - s.points_against as points_against_lead
    from from_standings s
    full outer join from_games g
        on  s.team_id = g.team_id
       and  s.season  = g.season

),

per_team_failures as (

    select
        case
            when standings_team_id is null then 'team_season_only_in_games'
            when least(win_lead, loss_lead, tie_lead,
                       home_win_lead, home_loss_lead, home_tie_lead,
                       road_win_lead, road_loss_lead, road_tie_lead,
                       points_for_lead, points_against_lead) < 0
                then 'standings_ahead_of_game_log'
            else 'lead_exceeds_tolerance'
        end                                             as issue,
        team_id,
        season,
        standings_wins,
        game_derived_wins,
        standings_losses,
        game_derived_losses,
        win_lead,
        loss_lead
    from leads
    where standings_team_id is null                     -- only in the game log
       -- the standings must never lead the game log, on any split or points
       or least(win_lead, loss_lead, tie_lead,
                home_win_lead, home_loss_lead, home_tie_lead,
                road_win_lead, road_loss_lead, road_tie_lead,
                points_for_lead, points_against_lead) < 0
       -- and the game log must not lead by more than the documented bound.
       -- Points excluded here: covered by the non-negativity check above
       -- and the league-wide balance below.
       or greatest(win_lead, loss_lead, tie_lead,
                   home_win_lead, home_loss_lead, home_tie_lead,
                   road_win_lead, road_loss_lead, road_tie_lead)
          > {{ max_team_game_lead }}

),

balance_failure as (

    -- Every game the log holds and the standings do not contributes exactly
    -- one win and one loss league-wide (a tie: two tie-legs, zero to both),
    -- and its points appear once as PF and once as PA. Exact checks, so the
    -- per-team tolerance cannot absorb a classification leak.
    select
        'league_leads_unbalanced'                       as issue,
        null                                            as team_id,
        null                                            as season,
        null                                            as standings_wins,
        null                                            as game_derived_wins,
        null                                            as standings_losses,
        null                                            as game_derived_losses,
        sum(win_lead)                                   as win_lead,
        sum(loss_lead)                                  as loss_lead
    from leads
    having sum(win_lead) <> sum(loss_lead)
        or mod(sum(tie_lead), 2) <> 0
        or sum(points_for_lead) <> sum(points_against_lead)

)

select * from per_team_failures
union all
select * from balance_failure
