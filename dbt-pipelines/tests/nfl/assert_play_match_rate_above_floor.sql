{#
    assert_play_match_rate_above_floor -- the play-level nflverse match keeps
    the rate it was measured at.

    Baseline (docs/nfl-enrichment-columns.html): 99.7% of the 129k matchable
    plays match through the T1/T2/T3 cascade, and no healthy game sits far
    below that. Two ways to fail, both returned as rows:

      * a game whose match_rate drops under the per-game floor (97%) -- a
        single game slipping usually means one feed's clock or yardline went
        strange in that broadcast;
      * the overall rate under 99% -- a systemic slip (vocabulary change,
        bridge drift) that per-game noise would hide.

    warn, not error: an unmatched play keeps NULL analytics rather than wrong
    ones, so a slipping rate degrades coverage, never correctness. The floors
    are vars so they can be raised as the residual shrinks.

    Override: --vars '{nfl_play_match_game_floor: 0.98, nfl_play_match_overall_floor: 0.995}'
#}

{{ config(severity='warn') }}

{% set game_floor = var('nfl_play_match_game_floor', 0.97) %}
{% set overall_floor = var('nfl_play_match_overall_floor', 0.99) %}

with per_game as (

    select
        game_key,
        season,
        week,
        matchable_plays,
        matched_plays,
        match_rate
    from {{ ref('fact_play_match_audit') }}

),

game_failures as (

    select
        'game under floor'                          as failure,
        game_key,
        season,
        week,
        matchable_plays,
        matched_plays,
        match_rate
    from per_game
    where match_rate < {{ game_floor }}

),

overall_failure as (

    select
        'overall under floor'                       as failure,
        cast(null as varchar)                       as game_key,
        cast(null as number)                        as season,
        cast(null as number)                        as week,
        sum(matchable_plays)                        as matchable_plays,
        sum(matched_plays)                          as matched_plays,
        sum(matched_plays) / sum(matchable_plays)   as match_rate
    from per_game
    having sum(matched_plays) / sum(matchable_plays) < {{ overall_floor }}

)

select * from game_failures
union all
select * from overall_failure
