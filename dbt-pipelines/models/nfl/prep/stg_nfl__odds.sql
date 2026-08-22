{{ config(materialized='view') }}

/*
    Historical game-line snapshots. Grain: API odds id x SCD2 version.
    snapshot_observed_at is deliberately the later of the provider update and
    dlt validity start: a line loaded after kickoff is not a pregame observation
    merely because its provider timestamp is older.
*/

with source as (

    select
        *,
        object_construct_keep_null(*) as raw_record
    from {{ source('nfl_raw', 'odds') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['id', '_dlt_valid_from']) }} as game_odds_snapshot_key,
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
    try_to_timestamp_tz(updated_at::string)                          as source_updated_at,
    _dlt_valid_from                                                  as valid_from,
    _dlt_valid_to                                                    as valid_to,
    (_dlt_valid_to is null)                                          as is_current,
    greatest_ignore_nulls(
        try_to_timestamp_tz(updated_at::string),
        _dlt_valid_from
    )                                                                as snapshot_observed_at,
    try_to_double(_dlt_load_id)                                      as dlt_load_id_numeric,
    to_timestamp_tz(try_to_double(_dlt_load_id))                     as loaded_at
from source
