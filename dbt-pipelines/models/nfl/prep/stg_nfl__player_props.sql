{{ config(materialized='view') }}

/*
    Historical player-prop snapshots. Grain: API prop id x SCD2 version.
    The API has emitted both generic market odds and side-specific over/under
    odds; all are retained rather than guessing which shape a prop type uses.
*/

with source as (

    select
        *,
        object_construct_keep_null(*) as raw_record
    from {{ source('nfl_raw', 'player_props') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['id', '_dlt_valid_from']) }} as player_prop_snapshot_key,
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
