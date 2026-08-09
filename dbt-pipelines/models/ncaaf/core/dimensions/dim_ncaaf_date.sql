{{
    config(
        materialized='table'
    )
}}

/*
    dim_ncaaf_date -- conformed calendar. Grain: date. Dense generated spine
    (every date in range exists whether or not games were played).

    Range: 1 January of the earliest standings season to the later of the
    last standings year end and 60 days past the last scheduled game. The
    60-day tail matters here more than in the WNBA: bowls and the CFP are
    scheduled late and land in January, so the spine widens on its own as
    the postseason slate loads.

    ncaaf_season does NOT equal calendar year: a college season runs August
    to January, so January and February dates belong to the PREVIOUS year's
    season (the CFP final for season 2026 is played in January 2027). Same
    rollover the ingestion layer uses (month 8). Published as its own column
    so a query written against any sport's date dimension reads the same.

    NO WEEK COLUMN, deliberately: week numbers live on games (and 999 means
    postseason), not on the calendar. A calendar week would disagree with
    the league week around bye-heavy and championship weeks.
*/

with season_bounds as (

    select
        min(season)                             as first_season,
        max(season)                             as last_season
    from {{ ref('stg_ncaaf__standings') }}

),

game_bounds as (

    select max(game_date)                       as last_game_date
    from {{ ref('stg_ncaaf__games') }}

),

bounds as (

    select
        date_from_parts(first_season, 1, 1)     as start_date,
        greatest(
            date_from_parts(last_season, 12, 31),
            dateadd(day, 60, last_game_date)
        )                                       as end_date
    from season_bounds
    cross join game_bounds

),

spine as (

    select date_day
    from (
        select
            dateadd(day, seq4(), (select start_date from bounds))::date as date_day
        from table(generator(rowcount => 10000))
    )
    where date_day <= (select end_date from bounds)

)

select
    {{ dbt_utils.generate_surrogate_key(['date_day']) }} as date_key,
    date_day                                  as full_date,

    year(date_day)                            as calendar_year,
    month(date_day)                           as calendar_month,
    monthname(date_day)                       as month_name,
    dayofweek(date_day)                       as day_of_week,
    dayname(date_day)                         as day_name,

    -- August rollover: January's bowl games belong to the previous year's
    -- season. Mirrors the ingestion layer's season_rollover_month: 8.
    iff(month(date_day) >= 8,
        year(date_day),
        year(date_day) - 1)                   as ncaaf_season,

    -- dayname(), not dayofweek(): the latter's numbering depends on the
    -- session WEEK_START parameter (see dim_wnba_date).
    (dayname(date_day) in ('Sat', 'Sun'))     as is_weekend

from spine
