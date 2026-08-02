{{
    config(
        materialized='table'
    )
}}

/*
    dim_date -- conformed calendar. Grain: date.

    Generated with a row-count spine rather than sourced, so it is dense: every
    date in the range exists whether or not a game was played on it. That is the
    point of a date dimension -- gaps in the fact should not create gaps here.

    Range runs from the day before the earliest game to the day after the latest,
    derived from the games table so it grows automatically as seasons load.
    Currently 2023-08-04 to 2026-02-08.

    nfl_season is NOT the same as calendar year: a season spans two calendar
    years (the 2025 season ends in February 2026), so January and February dates
    belong to the previous year's season. Getting this wrong would misattribute
    every playoff game.
*/

with bounds as (

    select
        dateadd(day, -1, min(game_date)) as start_date,
        dateadd(day,  1, max(game_date)) as end_date
    from {{ ref('stg_nfl__games') }}

),

spine as (

    -- generator produces a fixed 10,000-day runway; the outer filter trims it
    -- back to the actual game-date range. QUALIFY cannot be used here because
    -- there is no window function, so the trim happens in a wrapping select.
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
    quarter(date_day)                         as calendar_quarter,
    month(date_day)                           as calendar_month,
    monthname(date_day)                       as month_name,
    day(date_day)                             as day_of_month,
    dayofweek(date_day)                       as day_of_week,
    dayname(date_day)                         as day_name,
    weekofyear(date_day)                      as week_of_year,

    -- an NFL season starting in year N runs through February of year N+1, so
    -- January and February belong to the prior season
    case
        when month(date_day) <= 2 then year(date_day) - 1
        else year(date_day)
    end                                       as nfl_season,

    -- Day flags use dayname(), not dayofweek(), on purpose. dayofweek()'s
    -- numbering depends on the session WEEK_START parameter: at the default 0 it
    -- returns Sun=0..Sat=6, but under WEEK_START=1 it returns Mon=1..Sun=7, at
    -- which point a hardcoded `= 0` silently becomes always-false with no error.
    -- dayname() is stable regardless.
    --
    -- There is deliberately NO is_typical_game_day flag. The obvious version
    -- (Sun/Mon/Thu) is wrong for this data: Saturday hosts 94 games and Friday
    -- 80, against Thursday's 17, so filtering on it would discard 23% of the
    -- schedule. Which days have games is a property of the fact, not the
    -- calendar -- join to fact_team_game instead of guessing here.
    (dayname(date_day) = 'Sun')               as is_sunday,
    (dayname(date_day) = 'Mon')               as is_monday,
    (dayname(date_day) = 'Thu')               as is_thursday,
    (dayname(date_day) = 'Sat')               as is_saturday

from spine
