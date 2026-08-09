{{
    config(
        materialized='table'
    )
}}

/*
    dim_wnba_date -- conformed calendar. Grain: date. 6,940 rows.

    Generated with a row-count spine rather than sourced, so it is dense:
    every date in the range exists whether or not a game was played on it.
    That is the point of a date dimension -- gaps in the fact should not
    create gaps here.

    THE RANGE IS DRIVEN BY STANDINGS, NOT BY GAMES, and that is the
    difference from dim_wnba_date on the NFL side. stg_wnba__games covers the 2026
    season only, so a games-derived spine would stop at 2026 and leave every
    standings row from 2008 to 2025 with no calendar to join to.
    stg_wnba__standings spans 19 seasons but carries no dates at all, only a
    season integer, so the spine runs from 1 January of its earliest season to
    31 December of its latest. Today that is 2008-01-01 to 2026-12-31, and it
    widens on its own as seasons load.

    The end bound takes the later of that year end and 30 days past the last
    scheduled game, which costs nothing today (the last game is 2026-09-25,
    well inside 2026) and keeps the spine covering the schedule if a future
    load ever runs past the last standings season.

    wnba_season IS the calendar year, unlike nfl_season. A WNBA season runs
    May to October and closes inside one calendar year, so there is no
    January rollover to get wrong. It is published as its own column anyway
    rather than expecting consumers to use calendar_year, so that a query
    written against one sport's date dimension reads the same as the other's.

    NO WEEK CONCEPT. The WNBA schedule has no week structure, there is no
    dim_season_week on this side, and nothing joins on one.
*/

with season_bounds as (

    select
        min(season)                             as first_season,
        max(season)                             as last_season
    from {{ ref('stg_wnba__standings') }}

),

game_bounds as (

    select max(game_date)                       as last_game_date
    from {{ ref('stg_wnba__games') }}

),

bounds as (

    select
        date_from_parts(first_season, 1, 1)     as start_date,
        greatest(
            date_from_parts(last_season, 12, 31),
            dateadd(day, 30, last_game_date)
        )                                       as end_date
    from season_bounds
    cross join game_bounds

),

spine as (

    -- generator produces a fixed 10,000-day runway; the outer filter trims it
    -- back to the bounds above. QUALIFY cannot be used here because there is
    -- no window function, so the trim happens in a wrapping select.
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

    -- a WNBA season sits inside one calendar year -- see header
    year(date_day)                            as wnba_season,

    -- Weekend uses dayname(), not dayofweek(), on purpose. dayofweek()'s
    -- numbering depends on the session WEEK_START parameter: at the default 0
    -- it returns Sun=0..Sat=6, but under WEEK_START=1 it returns Mon=1..Sun=7,
    -- at which point a hardcoded `in (0, 6)` silently becomes wrong with no
    -- error. dayname() is stable regardless.
    (dayname(date_day) in ('Sat', 'Sun'))     as is_weekend

from spine
