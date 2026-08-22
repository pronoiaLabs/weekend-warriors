{{ config(materialized='view') }}

/*
    Opening game lines. Grain: one immutable API opening row.
    object_construct_keep_null makes optional season_type and dlt numeric
    variant twins safe to read even when a particular load did not create them.
*/

with source as (

    select
        *,
        object_construct_keep_null(*) as raw_record
    from {{ source('nfl_raw', 'odds_opening') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['id']) }}                    as game_odds_opening_key,
    {{ dbt_utils.generate_surrogate_key(['game_id']) }}               as game_key,
    id                                                               as source_odds_id,
    game_id,
    lower(nullif(trim(vendor), ''))                                  as vendor,
    try_to_decimal(coalesce(
        spread_home_value::string,
        raw_record:'SPREAD_HOME_VALUE__V_DOUBLE'::string
    ), 18, 4)                                                        as home_spread,
    try_to_number(spread_home_odds)                                  as home_spread_odds,
    try_to_decimal(coalesce(
        spread_away_value::string,
        raw_record:'SPREAD_AWAY_VALUE__V_DOUBLE'::string
    ), 18, 4)                                                        as away_spread,
    try_to_number(spread_away_odds)                                  as away_spread_odds,
    try_to_number(moneyline_home_odds)                               as home_moneyline_odds,
    try_to_number(moneyline_away_odds)                               as away_moneyline_odds,
    try_to_decimal(coalesce(
        total_value::string,
        raw_record:'TOTAL_VALUE__V_DOUBLE'::string
    ), 18, 4)                                                        as total_line,
    try_to_number(total_over_odds)                                   as over_odds,
    try_to_number(total_under_odds)                                  as under_odds,
    try_to_number(raw_record:'SEASON_TYPE'::string)                  as season_type,
    try_to_timestamp_tz(opened_at::string)                           as opened_at,
    try_to_double(_dlt_load_id)                                      as dlt_load_id_numeric,
    to_timestamp_tz(try_to_double(_dlt_load_id))                     as loaded_at
from source
