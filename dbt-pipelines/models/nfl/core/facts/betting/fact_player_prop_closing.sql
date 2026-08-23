{{ config(materialized='table') }}

/*
    Closing player props. Grain: game x player x vendor x prop_type.
    The chosen row is the latest snapshot observed strictly before kickoff.
    No result is graded: prop_type has no verified mapping to the heterogeneous
    NFL box-score columns, so exposing a fabricated outcome would be unsafe.
*/

with eligible as (

    select
        p.*,
        g.game_datetime,
        g.game_date,
        g.date_key,
        g.season,
        g.week,
        g.season_type as game_season_type,
        g.season_type_name,
        g.season_week_key,
        g.home_team_key,
        g.away_team_key
    from {{ ref('stg_nfl__player_props') }} p
    inner join {{ ref('dim_game') }} g on p.game_key = g.game_key
    where p.snapshot_observed_at < g.game_datetime

),

ranked as (

    select
        *,
        row_number() over (
            partition by game_id, player_id, vendor, prop_type
            order by snapshot_observed_at desc, valid_from desc, source_prop_id desc
        ) as logical_row_number
    from eligible

)

select
    {{ dbt_utils.generate_surrogate_key(
        ['p.game_id', 'p.player_id', 'p.vendor', 'p.prop_type']
    ) }}                                                            as game_player_vendor_prop_key,
    p.game_key,
    p.game_id,
    p.player_key,
    p.player_id,
    p.date_key,
    p.season_week_key,
    p.home_team_key,
    p.away_team_key,
    p.source_prop_id,
    p.vendor,
    p.prop_type,
    p.market_type,
    'closing'                                                       as line_timing,
    p.game_datetime,
    p.game_date,
    p.season,
    p.week,
    p.game_season_type                                              as season_type,
    p.season_type_name,
    p.snapshot_observed_at                                         as selected_snapshot_at,
    p.source_updated_at,
    p.valid_from,
    p.line_value,
    p.market_odds,
    p.over_odds,
    p.under_odds,
    o.line_value                                                   as opening_line_value,
    o.market_odds                                                  as opening_market_odds,
    o.over_odds                                                    as opening_over_odds,
    o.under_odds                                                   as opening_under_odds,
    p.line_value - o.line_value                                    as line_movement,
    p.market_odds - o.market_odds                                  as market_odds_movement,
    p.over_odds - o.over_odds                                      as over_odds_movement,
    p.under_odds - o.under_odds                                    as under_odds_movement,
    false                                                          as is_outcome_evaluation_available,
    'not modeled: prop types are not safely mapped to box-score measures'
                                                                   as outcome_evaluation_status,
    p.dlt_load_id_numeric,
    p.loaded_at
from ranked p
left join {{ ref('fact_player_prop_opening') }} o
    on  p.game_id = o.game_id
    and p.player_id = o.player_id
    and p.vendor = o.vendor
    and p.prop_type = o.prop_type
where p.logical_row_number = 1
