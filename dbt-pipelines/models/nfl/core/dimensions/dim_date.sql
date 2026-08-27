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

),

-- Observed phase windows per season, for season_phase. Pure derivation from
-- the games already loaded -- no new source. Each phase runs from its first
-- game to the day before the next phase starts, so the dark weeks between
-- phases classify with the phase being awaited rather than as gaps.
season_phases as (

    select
        season,
        min(iff(season_type = 1, game_date, null))      as preseason_start,
        min(iff(season_type = 2, game_date, null))      as regular_start,
        min(iff(season_type = 3, game_date, null))      as postseason_start,
        max(iff(season_type = 3, game_date, null))      as postseason_end
    from {{ ref('stg_nfl__games') }}
    group by season

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
    -- calendar -- join to fact_team_game_offense instead of guessing here.
    (dayname(date_day) = 'Sun')               as is_sunday,
    (dayname(date_day) = 'Mon')               as is_monday,
    (dayname(date_day) = 'Thu')               as is_thursday,
    (dayname(date_day) = 'Sat')               as is_saturday,

    -- Holiday slates: real analytical anchors for the slate page and props.
    -- Thanksgiving is the fourth Thursday of November, which always falls on
    -- the 22nd through the 28th; Black Friday is the Friday right after it
    -- (23rd through 29th). Derived from the calendar alone -- dayname() for
    -- the same WEEK_START reason as the flags above.
    (month(date_day) = 11 and dayname(date_day) = 'Thu'
        and day(date_day) between 22 and 28)  as is_thanksgiving,
    (month(date_day) = 11 and dayname(date_day) = 'Fri'
        and day(date_day) between 23 and 29)  as is_black_friday,
    (month(date_day) = 12 and day(date_day) = 25)  as is_christmas,
    (month(date_day) = 1  and day(date_day) = 1)   as is_new_years,

    -- Where this date sits in its NFL season's arc, from the observed phase
    -- windows: preseason runs from the first preseason game up to the first
    -- regular-season game, and so on through the Super Bowl; everything else
    -- (including a season whose games have not loaded yet) is offseason.
    case
        when sp.postseason_start is not null
            and date_day between sp.postseason_start and sp.postseason_end
            then 'postseason'
        when sp.regular_start is not null
            and date_day >= sp.regular_start
            and date_day < coalesce(sp.postseason_start, dateadd(day, 1, date_day))
            then 'regular'
        when sp.preseason_start is not null
            and date_day >= sp.preseason_start
            and date_day < coalesce(sp.regular_start, dateadd(day, 1, date_day))
            then 'preseason'
        else 'offseason'
    end                                       as season_phase

from spine
left join season_phases sp
    on sp.season = case
        when month(date_day) <= 2 then year(date_day) - 1
        else year(date_day)
    end
