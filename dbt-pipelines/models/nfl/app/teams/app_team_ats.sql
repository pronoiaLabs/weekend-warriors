{{
    config(
        materialized='table'
    )
}}

/*
    app_team_ats -- a team's record against the closing number, per book.

    Grain: team x season x season type x sportsbook. Aggregates app_team_weeks
    rows that carry a line, so the per-game cover and over calls and this table
    agree by construction. Empty for seasons before the odds feed (2026 is the
    first); the page says so rather than showing zeros.

    ats_pct excludes pushes from the denominator, the convention bettors use.
    favourite / underdog splits use the closing spread's sign from this team's
    side (negative = favourite).
*/

with weeks as (

    select * from {{ ref('app_team_weeks') }}
    where vendor is not null
      and spread_result is not null

),

agg as (

    select
        team_key,
        season,
        season_type,
        vendor,
        count(*)                                        as games_with_line,
        count_if(spread_result = 'cover')               as ats_wins,
        count_if(spread_result = 'loss')                as ats_losses,
        count_if(spread_result = 'push')                as ats_pushes,
        count_if(total_result = 'over')                 as overs,
        count_if(total_result = 'under')                as unders,
        count_if(total_result = 'push')                 as total_pushes,
        count_if(spread < 0)                            as favourite_games,
        count_if(spread < 0 and spread_result = 'cover')
                                                        as favourite_ats_wins,
        count_if(spread > 0)                            as underdog_games,
        count_if(spread > 0 and spread_result = 'cover')
                                                        as underdog_ats_wins,
        count_if(is_home and spread_result = 'cover')   as home_ats_wins,
        count_if(is_home and spread_result = 'loss')    as home_ats_losses,
        count_if(not is_home and spread_result = 'cover')
                                                        as away_ats_wins,
        count_if(not is_home and spread_result = 'loss')
                                                        as away_ats_losses,
        round(avg(spread), 2)                           as avg_spread,
        round(avg(total_line), 2)                       as avg_total_line,
        round(avg(margin_vs_spread), 2)                 as avg_margin_vs_spread,
        round(avg(total_points - total_line), 2)        as avg_total_vs_line
    from weeks
    group by 1, 2, 3, 4

)

select
    {{ dbt_utils.generate_surrogate_key(['a.team_key', 'a.season', 'a.season_type', 'a.vendor']) }}
                                                        as app_team_ats_key,
    a.team_key,
    t.team_id,
    t.team_abbreviation                                 as team_label,
    t.team_full_name                                    as team_name,
    a.season,
    a.season_type,
    st.season_type_name,
    a.vendor,
    a.games_with_line,
    a.ats_wins,
    a.ats_losses,
    a.ats_pushes,
    iff(a.ats_wins + a.ats_losses > 0, round(a.ats_wins / (a.ats_wins + a.ats_losses), 3), null)
                                                        as ats_pct,
    a.overs,
    a.unders,
    a.total_pushes,
    iff(a.overs + a.unders > 0, round(a.overs / (a.overs + a.unders), 3), null)
                                                        as over_pct,
    a.favourite_games,
    a.favourite_ats_wins,
    a.underdog_games,
    a.underdog_ats_wins,
    a.home_ats_wins,
    a.home_ats_losses,
    a.away_ats_wins,
    a.away_ats_losses,
    a.avg_spread,
    a.avg_total_line,
    a.avg_margin_vs_spread,
    a.avg_total_vs_line
from agg a
inner join {{ ref('dim_team') }} t
    on t.team_key = a.team_key
left join (
    select distinct season_type, season_type_name from {{ ref('dim_season_week') }}
) st
    on st.season_type = a.season_type
