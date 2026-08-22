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
        raw_record:SPREAD_HOME_VALUE__V_DOUBLE::string
    ), 18, 4)                                                        as home_spread,
    spread_home_odds::number                                        as home_spread_odds,
    try_to_decimal(coalesce(
        spread_away_value::string,
        raw_record:SPREAD_AWAY_VALUE__V_DOUBLE::string
    ), 18, 4)                                                        as away_spread,
    spread_away_odds::number                                        as away_spread_odds,
    moneyline_home_odds::number                                     as home_moneyline_odds,
    moneyline_away_odds::number                                     as away_moneyline_odds,
    try_to_decimal(coalesce(
        total_value::string,
        raw_record:TOTAL_VALUE__V_DOUBLE::string
    ), 18, 4)                                                        as total_line,
    total_over_odds::number                                         as over_odds,
    total_under_odds::number                                        as under_odds,
    season_type::number                                             as season_type,
    try_to_timestamp_tz(opened_at::string)                           as opened_at,
    try_to_double(_dlt_load_id)                                      as dlt_load_id_numeric,
    to_timestamp_tz(try_to_double(_dlt_load_id)::number)             as loaded_at
from source
