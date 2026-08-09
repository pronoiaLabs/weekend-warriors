{{
    config(
        materialized='view'
    )
}}

/*
    stg_wnba__player_injuries -- injury report, 38 rows.

    Like standings this is dlt SCD2; unlike standings the history is the
    point, so both validity timestamps are kept and the current flag is
    derived rather than filtered on. Today every row is the first version
    (_dlt_valid_to is NULL on all 38), so is_current is true throughout; the
    history accrues as the daily pipeline reruns.

    There is no report-date column here, unlike the NFL source. _dlt_valid_from
    is the only timestamp on the row, so it doubles as the report version and
    carries the surrogate key alongside player__id.

    RETURN_DATE is TEXT and has no year in it: values read 'Aug 10', 'Sep 17',
    'May 1'. A bare try_to_date on that returns NULL for all 38 rows, so the
    year is taken from _dlt_valid_from, which is when the report was pulled,
    and the two are parsed together with an explicit MON DD YYYY format. The
    raw text is kept beside it because the inference is ours, not the source's,
    and because it goes wrong across a New Year boundary: a December report
    naming 'Jan 5' would resolve to January of the year just ending. Eight
    rows already return 'May 1', a date months in the past by the time of the
    load, which is how this feed spells "out indefinitely".

    STATUS is 'Out' (31 rows) or 'Day-To-Day' (7).
*/

with source as (

    select * from {{ source('wnba_raw', 'player_injuries') }}

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['player__id', '_dlt_valid_from']) }}
                                                                as player_injury_key,
        {{ dbt_utils.generate_surrogate_key(['player__id']) }}    as player_key,
        player__id                                              as player_id,

        -- the injury source carries the player's team; kept because an injury
        -- is only meaningful against the team the player was with at the time
        {{ dbt_utils.generate_surrogate_key(['player__team__id']) }} as team_key,
        player__team__id                                        as team_id,

        nullif(trim(status), '')                                as injury_status,
        nullif(trim(comment), '')                               as injury_comment,

        -- year-less text plus the report year -- see header
        nullif(trim(return_date), '')                           as return_date_text,
        try_to_date(
            trim(return_date) || ' ' || year(_dlt_valid_from)::varchar,
            'MON DD YYYY'
        )                                                       as return_date,

        -- SCD2 validity from dlt
        _dlt_valid_from                                         as valid_from,
        _dlt_valid_to                                           as valid_to,
        (_dlt_valid_to is null)                                 as is_current

    from source

)

select * from renamed
