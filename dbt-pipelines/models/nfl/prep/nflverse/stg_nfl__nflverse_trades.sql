{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_trades -- the nflverse trades file, one row per asset
    moved. Grain: trade_id x asset (a trade with three pieces is three rows).

    An asset is either a player (pfr_id / pfr_name) or a draft pick
    (pick_season / pick_round / pick_number, conditional flag); the file uses
    empty strings rather than NULLs on the pick rows, nulled here so the
    either/or reads cleanly. gave / received are nflverse team abbreviations,
    kept as text: the file reaches back to 2002 and carries franchises
    dim_team does not (SD, OAK, STL). A handful of rows are exact duplicates
    in the file itself (same pick listed twice on a trade, 9 rows measured
    2026-08); they are kept -- the fact numbers assets within the trade.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_trades') }}

)

select
    trade_id::number                                    as trade_id,
    season::number                                      as season,
    trade_date,
    gave,
    received,
    nullif(pfr_id, '')                                  as pfr_id,
    nullif(pfr_name, '')                                as pfr_name,
    pick_season::number                                 as pick_season,
    pick_round::number                                  as pick_round,
    pick_number::number                                 as pick_number,
    conditional::boolean                                as conditional,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
