/*
    Every team game in the fact appears in app_team_weeks exactly once per book
    (or once with vendor NULL), and no team game is lost to a join. Three checks
    in one: every fact row present, per-game vendor rows equal the closing
    fact's vendors for that game, and the summed margins agree so no row was
    duplicated.
*/

with fact_side as (

    select
        count(*)                                        as team_games,
        sum(point_margin)                               as sum_margin
    from {{ ref('fact_team_game_offense') }}

),

app_side as (

    select
        count(distinct team_game_key)                   as team_games,
        sum(iff(vendor is null or vendor = first_vendor, point_margin, 0))
                                                        as sum_margin
    from (
        select
            w.*,
            min(w.vendor) over (partition by w.team_game_key) as first_vendor
        from {{ ref('app_team_weeks') }} w
    )

),

missing as (

    select count(*)                                     as n_missing
    from {{ ref('fact_team_game_offense') }} o
    left join {{ ref('app_team_weeks') }} w
        on w.team_game_key = o.team_game_key
    where w.team_game_key is null

),

vendor_rows as (

    select count(*)                                     as n_bad
    from (
        select
            w.team_game_key,
            count(w.vendor)                             as app_vendors,
            (select count(*) from {{ ref('fact_game_betting_odds_closing') }} c where c.game_key = w.game_key)
                                                        as fact_vendors
        from {{ ref('app_team_weeks') }} w
        group by w.team_game_key, w.game_key
    )
    where app_vendors <> fact_vendors

)

select
    f.team_games                                        as fact_team_games,
    a.team_games                                        as app_team_games,
    f.sum_margin                                        as fact_sum_margin,
    a.sum_margin                                        as app_sum_margin,
    m.n_missing,
    v.n_bad                                             as team_games_with_wrong_vendor_rows
from fact_side f
cross join app_side a
cross join missing m
cross join vendor_rows v
where f.team_games <> a.team_games
   or f.sum_margin <> a.sum_margin
   or m.n_missing > 0
   or v.n_bad > 0
