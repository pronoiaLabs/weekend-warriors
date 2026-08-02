{{
    config(
        materialized='view'
    )
}}

/*
    stg_nfl__player_injuries -- injury report.

    Only 21 rows today, so nothing here is load-bearing yet, but it grows with
    ongoing dlt loads. Like standings this is dlt SCD2; unlike standings the
    history is the point, so both validity timestamps are kept and the current
    flag is derived rather than filtered on.
*/

with source as (

    select * from {{ source('nfl_raw', 'player_injuries') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['player__id', 'date', '_dlt_valid_from']) }}
                                                                as player_injury_key,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}    as player_key,
        player__id                                              as player_id,

        -- the injury source carries the player's team; kept because an injury
        -- is only meaningful against the team the player was with at the time
        {{ dbt_utils.generate_surrogate_key(['player__team__id']) }} as team_key,
        player__team__id                                        as team_id,

        date                                                    as reported_at,
        date::date                                              as reported_date,
        nullif(trim(status), '')                                as injury_status,
        nullif(trim(comment), '')                               as injury_comment,

        -- SCD2 validity from dlt
        _dlt_valid_from                                         as valid_from,
        _dlt_valid_to                                           as valid_to,
        (_dlt_valid_to is null)                                 as is_current

    from source

)

select * from renamed
