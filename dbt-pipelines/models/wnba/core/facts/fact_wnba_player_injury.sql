{{
    config(
        materialized='table'
    )
}}

/*
    fact_wnba_player_injury -- injury report. Grain: player x report version. 38 rows.

    Sparse, like the NFL fact it mirrors, but it grows with every dlt load. The
    SCD2 history from the source is preserved rather than collapsed, so a
    status change over time is visible instead of overwritten. Today all 38
    rows are the first version, so is_current is true throughout and the flag
    looks redundant; it stops being redundant the first time the daily pipeline
    supersedes a row. Filter is_current for the live report -- without it a
    player with three status updates contributes three rows.

    NO REPORT DATE, UNLIKE THE NFL SOURCE. That source carries an explicit
    reported_at and this one carries nothing but dlt's _dlt_valid_from, which
    is when the report was pulled. So valid_from doubles as the report version
    and as the only timestamp on the row, and it is what carries the surrogate
    key alongside player_id. date_key is built from its date part, which is the
    same shape the NFL fact uses.

    NO GAME KEY, for the same reason as the NFL fact: the source reports an
    injury against a moment, not a game. Join through dim_wnba_date to place one in
    a season.

    return_date IS INFERRED AND CAN BE WRONG BY A YEAR. The source's
    RETURN_DATE is text with no year in it: 'Aug 10', 'Sep 17', 'May 1'. Prep
    supplies the year from valid_from, which is when the report was read, and
    parses the two together. The raw text is carried beside it because the
    inference is ours and not the source's, and because it goes wrong across a
    New Year boundary -- a December report naming 'Jan 5' resolves to January
    of the year just ending. Eight rows already read 'May 1', a date months in
    the past by the time of the load, which is how this feed spells "out
    indefinitely". Always show return_date_text to a human; use return_date
    only for ordering and arithmetic, and not across a year boundary.

    team_key is the player's team as the injury source reported it at the time,
    which is the right one: an injury is only meaningful against the club the
    player was with. It is populated on all 38 rows.
*/

with injuries as (

    select * from {{ ref('stg_wnba__player_injuries') }}

)

select
    -- keys
    player_injury_key,
    player_key,
    player_id,
    team_key,
    team_id,
    {{ dbt_utils.generate_surrogate_key(['valid_from::date']) }} as date_key,

    -- when. valid_from is the report version AND the report time -- see header.
    valid_from::date                    as reported_date,

    -- what
    injury_status,
    injury_comment,

    -- inferred year -- see header. Always show the text to a human.
    return_date_text,
    return_date,

    -- SCD2 validity
    valid_from,
    valid_to,
    is_current

from injuries
