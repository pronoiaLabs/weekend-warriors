/*
    Recompute the leakage-safe latest snapshot from PREP and compare its source
    identity and observation timestamp with each CORE closing fact.
*/

with expected_game as (

    select
        o.game_id,
        o.vendor,
        o.source_odds_id,
        o.snapshot_observed_at,
        row_number() over (
            partition by o.game_id, o.vendor
            order by o.snapshot_observed_at desc, o.valid_from desc, o.source_odds_id desc
        ) as logical_row_number
    from {{ ref('stg_nfl__odds') }} o
    inner join {{ ref('dim_game') }} g on o.game_key = g.game_key
    where o.snapshot_observed_at < g.game_datetime

),

game_mismatches as (

    select
        'game_odds' as market,
        e.game_id,
        null::number as player_id,
        e.vendor,
        null::string as prop_type,
        e.source_odds_id::string as expected_source_id,
        c.source_odds_id::string as actual_source_id
    from expected_game e
    left join {{ ref('fact_game_betting_odds_closing') }} c
        on e.game_id = c.game_id and e.vendor = c.vendor
    where e.logical_row_number = 1
      and (
          c.source_odds_id is null
          or c.source_odds_id != e.source_odds_id
          or c.selected_snapshot_at != e.snapshot_observed_at
      )

),

expected_props as (

    select
        p.game_id,
        p.player_id,
        p.vendor,
        p.prop_type,
        p.source_prop_id,
        p.snapshot_observed_at,
        row_number() over (
            partition by p.game_id, p.player_id, p.vendor, p.prop_type
            order by p.snapshot_observed_at desc, p.valid_from desc, p.source_prop_id desc
        ) as logical_row_number
    from {{ ref('stg_nfl__player_props') }} p
    inner join {{ ref('dim_game') }} g on p.game_key = g.game_key
    where p.snapshot_observed_at < g.game_datetime

),

prop_mismatches as (

    select
        'player_prop' as market,
        e.game_id,
        e.player_id,
        e.vendor,
        e.prop_type,
        e.source_prop_id::string as expected_source_id,
        c.source_prop_id::string as actual_source_id
    from expected_props e
    left join {{ ref('fact_player_prop_closing') }} c
        on  e.game_id = c.game_id
        and e.player_id = c.player_id
        and e.vendor = c.vendor
        and e.prop_type = c.prop_type
    where e.logical_row_number = 1
      and (
          c.source_prop_id is null
          or c.source_prop_id != e.source_prop_id
          or c.selected_snapshot_at != e.snapshot_observed_at
      )

)

select * from game_mismatches
union all
select * from prop_mismatches
