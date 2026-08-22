/*
    The two independent sources of a defense's game must agree where they
    overlap: the player-stat rollup (pressure / coverage block) and the
    opponent's team box score (allowed block) come from different provider
    endpoints, so a mismatch is either a broken rollup or a broken self-join.

    Two measures overlap, with different tolerances, both measured on the
    2,044 team-games that have both sides (Aug 2026):

      * interceptions: sum of player defensive_interceptions equals the
        opponent's interceptions_thrown on EVERY row. Asserted exactly, both
        sides coalesced to 0 so "no player credited" and "team box says 0"
        agree.
      * sacks: sum of player defensive_sacks (FLOAT, half-sacks) differs from
        the opponent's sacks_allowed by more than 0.5 on 18 rows, never by
        more than 1.0. Asserted within 1.0; the baseline is recorded so a
        widening gap reads as a change, not as noise.

    NOT asserted, on purpose:
      * fumbles_recovered vs the opponent's fumbles_lost: 841 mismatches,
        because the player stat counts own-fumble recoveries too. The fact's
        takeaways column uses the opponent's turnovers for exactly this reason.
      * defensive_touchdowns_team_box vs defensive_touchdowns_player_rollup:
        155 mismatches with no way to adjudicate; both are exposed.

    Scoped to rows where both sides exist. A row with no opponent box score
    or no player rollup has nothing to reconcile and is covered by the
    has_* flags instead.
*/

{% set max_sack_gap = 1.0 %}

select
    team_game_key,
    game_id,
    team_id,
    season,
    week,
    interceptions_recorded,
    opp_interceptions_thrown,
    sacks_recorded,
    opp_sacks_allowed,
    case
        when coalesce(interceptions_recorded, 0) <> coalesce(opp_interceptions_thrown, 0)
            then 'interceptions_disagree'
        else 'sack_gap_exceeds_tolerance'
    end                                                         as issue
from {{ ref('fact_team_game_defense') }}
where has_opp_box_score
  and has_player_defense
  and (
         coalesce(interceptions_recorded, 0) <> coalesce(opp_interceptions_thrown, 0)
      or abs(coalesce(sacks_recorded, 0) - coalesce(opp_sacks_allowed, 0)) > {{ max_sack_gap }}
  )
