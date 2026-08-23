{{ config(materialized='table') }}

/*
    Opening player props. Grain: game x player x vendor x prop_type.
    Multiple API ids at that logical grain resolve to the earliest opened row,
    then load timestamp and source id for deterministic ties.
*/

with ranked as (

    select
        p.*,
        row_number() over (
            partition by p.game_id, p.player_id, p.vendor, p.prop_type
            order by p.opened_at asc nulls last, p.loaded_at asc, p.source_prop_id
        ) as logical_row_number
    from {{ ref('stg_nfl__player_props_opening') }} p

)

select
    {{ dbt_utils.generate_surrogate_key(
        ['p.game_id', 'p.player_id', 'p.vendor', 'p.prop_type']
    ) }}                                                            as game_player_vendor_prop_key,
    p.game_key,
    p.game_id,
    p.player_key,
    p.player_id,
    g.date_key,
    g.season_week_key,
    g.home_team_key,
    g.away_team_key,
    p.source_prop_id,
    p.vendor,
    p.prop_type,
    p.market_type,
    'opening'                                                       as line_timing,
    g.game_datetime,
    g.game_date,
    g.season,
    g.week,
    g.season_type,
    g.season_type_name,
    p.opened_at                                                     as selected_snapshot_at,
    p.line_value,
    p.market_odds,
    p.over_odds,
    p.under_odds,
    false                                                           as is_outcome_evaluation_available,
    'not modeled: prop types are not safely mapped to box-score measures'
                                                                    as outcome_evaluation_status,
    p.dlt_load_id_numeric,
    p.loaded_at
from ranked p
inner join {{ ref('dim_game') }} g on p.game_key = g.game_key
where p.logical_row_number = 1
