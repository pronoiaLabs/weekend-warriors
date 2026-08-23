{{
    config(
        materialized='table'
    )
}}

/*
    fact_player_injury -- injury report. Grain: player x report date x SCD2 version.

    Only 21 rows today. Sparse, but it grows with every dlt load, and the SCD2
    history from the source is preserved so status changes over time are visible
    rather than overwritten.

    is_current filters to the live view of the report. Without it, a player with
    three status updates contributes three rows.

    No game_key: the source reports injuries against a date, not a game.
    Join through dim_date, or to dim_season_week via the date, to place an injury
    in the season.
*/

with injuries as (

    select * from {{ ref('stg_nfl__player_injuries') }}

)

select
    -- keys
    player_injury_key,
    player_key,
    player_id,
    team_key,
    team_id,
    {{ dbt_utils.generate_surrogate_key(['reported_date']) }} as date_key,

    -- when
    reported_at,
    reported_date,

    -- what
    injury_status,
    injury_comment,

    -- SCD2 validity
    valid_from,
    valid_to,
    is_current

from injuries
