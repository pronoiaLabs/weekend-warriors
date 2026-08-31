-- The vocabulary pin: app_play_log copies its play_family CASE and is_epa_play
-- base filter from fact_team_game_situation, and this test fails the moment
-- either copy drifts. Pinned at GAME level on coverage-parity games: where the
-- log's is_epa_play count equals the fact's play count (every scrimmage play
-- matched), the dropback/carry split must agree EXACTLY -- measured at zero
-- mismatches over 450 games. Team-level totals are deliberately not compared:
-- BDL's possession attribution disagrees with nflverse's posteam on a small
-- share of plays (documented on the mart), which shifts counts between a
-- game's two teams without touching the classification this test guards.

with log_side as (

    select
        game_key,
        count_if(is_epa_play)                           as epa_plays,
        count_if(is_epa_play and play_family = 'dropback')
                                                        as dropbacks,
        count_if(is_epa_play and play_family = 'designed_run')
                                                        as carries
    from {{ ref('app_play_log') }}
    group by 1

),

fact_side as (

    select
        game_key,
        sum(plays)                                      as plays,
        sum(dropbacks)                                  as dropbacks,
        sum(carries)                                    as carries
    from {{ ref('fact_team_game_situation') }}
    where side = 'offense'
    group by 1

)

select
    f.game_key,
    l.dropbacks                                         as log_dropbacks,
    f.dropbacks                                         as fact_dropbacks,
    l.carries                                           as log_carries,
    f.carries                                           as fact_carries
from fact_side f
inner join log_side l
    on l.game_key = f.game_key
where l.epa_plays = f.plays
  and (l.dropbacks <> f.dropbacks or l.carries <> f.carries)
