{{ config(materialized='view') }}

{#
    stg_nfl__nflverse_depth_charts -- daily depth-chart snapshots, 2025 on.
    Grain: chart_date x team x formation package x slot position x slot x rank.

    The league's chart as published each day: pos_grp is the package the
    chart is drawn for ("3WR 1TE", "Base 3-4 D"), pos_abb the slot position
    within it (LG, RT, LCB, NB), pos_slot separates same-position slots (the
    three WR spots), pos_rank the depth within the slot.

    dt is a full TIMESTAMP, and the league occasionally publishes twice in
    one day (measured: 221 timestamps over 219 dates; 2025-08-09 has a 07:14
    and a 19:43 chart). A calendar day is the grain consumers want, so the
    QUALIFY keeps only each team's LAST snapshot of the day -- the chart in
    effect at day's end -- and chart_at preserves the exact publication time.

    The 2001 to 2024 weekly shape lives in stg_nfl__nflverse_depth_charts_weekly;
    the two are unified game-anchored in fact_depth_chart.
#}

with source as (

    select * from {{ source('nfl_raw', 'nflverse_depth_charts') }}

)

select
    to_timestamp_tz(dt::string)                         as chart_at,
    try_to_date(dt::string)                             as chart_date,
    season,
    team,
    pos_grp_id,
    pos_grp                                             as formation,
    pos_id,
    pos_abb                                             as position,
    pos_name                                            as position_name,
    pos_slot                                            as depth_slot,
    pos_rank                                            as depth_rank,
    gsis_id,
    try_to_number(espn_id::string)::string              as espn_id,
    player_name,
    to_timestamp_tz(_dlt_load_id::float::number)        as loaded_at
from source
qualify dt = max(dt) over (partition by try_to_date(dt::string), team)
