{{
    config(
        materialized='table'
    )
}}

/*
    fact_play_match_audit -- the play-level nflverse match, audited per game
    (physical table PLAY_MATCH_AUDIT). Grain: game, matchable games only.

    "Audit, don't assume": the graft on fact_play is only trustworthy while
    the match rate stays where it was measured (99.7% overall;
    docs/nfl-enrichment-columns.html). This rolls the per-play outcome up to
    the grain a human investigates at -- which GAME slipped, and to which
    tier the matches degraded. A game drifting from T1-heavy to T3-heavy is
    an early warning (clock or yardline vocabulary drift) even while the
    total rate still clears the floor.

    Only matchable plays are counted, so preseason games and the ~27k
    administrative rows never dilute the rate; games with zero matchable
    plays have no row. tests/nfl/assert_play_match_rate_above_floor reads
    this table.
*/

select
    game_key,
    season,
    week,
    season_type,

    count(*)                                        as matchable_plays,
    count_if(match_tier = 'T1')                     as matched_t1,
    count_if(match_tier = 'T2')                     as matched_t2,
    count_if(match_tier = 'T3')                     as matched_t3,
    count_if(match_tier is not null)                as matched_plays,
    count_if(match_tier is not null) / count(*)     as match_rate

from {{ ref('fact_play') }}
where is_matchable
group by game_key, season, week, season_type
