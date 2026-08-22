{{ config(materialized='view') }}

/*
    Opening player props. Grain: one immutable API opening row. CORE resolves
    duplicate API ids at the logical game x player x vendor x prop_type grain.
*/

with source as (

    select
        *,
        object_construct_keep_null(*) as raw_record
    from {{ source('nfl_raw', 'player_props_opening') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['id']) }}                    as player_prop_opening_key,
    {{ dbt_utils.generate_surrogate_key(['game_id']) }}               as game_key,
    {{ dbt_utils.generate_surrogate_key(['player_id']) }}             as player_key,
    id                                                               as source_prop_id,
    game_id,
    player_id,
    lower(nullif(trim(vendor), ''))                                  as vendor,
    lower(nullif(trim(prop_type), ''))                               as prop_type,
    lower(nullif(trim(market__type::string), ''))                    as market_type,
    try_to_decimal(coalesce(
        line_value::string,
        raw_record:LINE_VALUE__V_DOUBLE::string
    ), 18, 4)                                                        as line_value,
    try_to_number(market__odds)                                      as market_odds,
    try_to_number(market__over_odds)                                 as over_odds,
    try_to_number(market__under_odds)                                as under_odds,
    try_to_number(raw_record:SEASON_TYPE::string)                    as season_type,
    try_to_timestamp_tz(opened_at::string)                           as opened_at,
    try_to_double(_dlt_load_id)                                      as dlt_load_id_numeric,
    to_timestamp_tz(try_to_double(_dlt_load_id))                     as loaded_at
from source
