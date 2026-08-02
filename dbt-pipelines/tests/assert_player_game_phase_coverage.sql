/*
    Guard the player-game phase split.

    The three phase facts are carved out of one 67,191-row source by activity,
    which means two invariants have to hold and neither is obvious from row
    counts alone:

    1. NO ROW IS LOST UNEXPECTEDLY. Every STATS row either lands in at least one
       phase fact, or it genuinely has no activity in any phase. Exactly 5 rows
       are in the second category: backup quarterbacks and linemen who dressed
       and recorded nothing at all -- every measure on those rows is NULL.
       Verified individually, not assumed.

       This threshold started at 386. That number was the bug, not the baseline:
       381 of those rows were player-games whose only recorded action was a
       fumble, and the phase filters omitted the fumble columns even though the
       facts published them. Fixing the filters recovered all 381. If this test
       fails with a number above 5, suspect the same class of error -- a measure
       published by a fact but missing from its activity filter.

    2. NO ROW IS INVENTED. Every key in a phase fact must exist in the source.

    Deliberately NOT tested: that the three facts' row counts sum to 67,191.
    They do not, and should not -- 4,613 player-games have activity in multiple
    phases and correctly appear in multiple facts.

    The threshold is asserted exactly rather than as an upper bound so that a
    DECREASE also fails. A drop would mean the source changed shape, which is
    worth a look even though it sounds like an improvement.
*/

{% set expected_no_phase_rows = 5 %}

with source_stats as (

    select player_game_key from {{ ref('stg_nfl__player_stats') }}

),

in_any_phase as (

    select player_game_key from {{ ref('fact_player_game_offense') }}
    union
    select player_game_key from {{ ref('fact_player_game_defense') }}
    union
    select player_game_key from {{ ref('fact_player_game_special') }}

),

orphaned_in_facts as (

    -- a key in a fact that is not in the source: impossible unless a join
    -- fanned out or a key was rebuilt inconsistently
    select
        'key_in_fact_not_in_source' as issue,
        count(*)                    as n
    from in_any_phase p
    left join source_stats s
        on p.player_game_key = s.player_game_key
    where s.player_game_key is null

),

unphased as (

    -- source rows landing in no phase fact
    select
        'source_rows_in_no_phase'   as issue,
        count(*)                    as n
    from source_stats s
    left join in_any_phase p
        on s.player_game_key = p.player_game_key
    where p.player_game_key is null

)

select issue, n from orphaned_in_facts where n <> 0
union all
select issue, n from unphased        where n <> {{ expected_no_phase_rows }}
