{{ config(materialized='table') }}

/*
    Closing game markets. Grain: game x vendor.

    "Closing" means the latest snapshot OBSERVED strictly before kickoff.
    snapshot_observed_at is the later of provider updated_at and dlt valid_from,
    so a row first seen after kickoff can never leak into this model.
*/

with eligible as (

    select
        o.*,
        g.game_datetime,
        g.game_date,
        g.date_key,
        g.season,
        g.week,
        g.season_type,
        g.season_type_name,
        g.season_week_key,
        g.home_team_key,
        g.home_team_id,
        g.away_team_key,
        g.away_team_id,
        g.is_completed
    from {{ ref('stg_nfl__odds') }} o
    inner join {{ ref('dim_game') }} g on o.game_key = g.game_key
    where o.snapshot_observed_at < g.game_datetime

),

ranked as (

    select
        *,
        row_number() over (
            partition by game_id, vendor
            order by snapshot_observed_at desc, valid_from desc, source_odds_id desc
        ) as logical_row_number
    from eligible

),

home_results as (

    select * from {{ ref('fact_team_game') }} where is_home

),

joined as (

    select
        c.*,
        r.points_scored as home_team_score,
        r.points_allowed as away_team_score,
        o.home_spread as opening_home_spread,
        o.away_spread as opening_away_spread,
        o.home_spread_odds as opening_home_spread_odds,
        o.away_spread_odds as opening_away_spread_odds,
        o.home_moneyline_odds as opening_home_moneyline_odds,
        o.away_moneyline_odds as opening_away_moneyline_odds,
        o.total_line as opening_total_line,
        o.over_odds as opening_over_odds,
        o.under_odds as opening_under_odds
    from ranked c
    left join home_results r on c.game_key = r.game_key
    left join {{ ref('fact_game_betting_odds_opening') }} o
        on  c.game_key = o.game_key
        and c.vendor = o.vendor
    where c.logical_row_number = 1

)

select
    {{ dbt_utils.generate_surrogate_key(['game_id', 'vendor']) }} as game_vendor_odds_key,
    game_key,
    game_id,
    date_key,
    season_week_key,
    home_team_key,
    home_team_id,
    away_team_key,
    away_team_id,
    source_odds_id,
    vendor,
    'closing'                                                       as line_timing,
    game_datetime,
    game_date,
    season,
    week,
    season_type,
    season_type_name,
    snapshot_observed_at                                           as selected_snapshot_at,
    source_updated_at,
    valid_from,
    home_spread,
    home_spread_odds,
    away_spread,
    away_spread_odds,
    home_moneyline_odds,
    away_moneyline_odds,
    total_line,
    over_odds,
    under_odds,
    iff(home_moneyline_odds < 0,
        -home_moneyline_odds / (-home_moneyline_odds + 100.0),
        iff(home_moneyline_odds > 0, 100.0 / (home_moneyline_odds + 100.0), null)
    )                                                               as home_moneyline_implied_probability,
    iff(away_moneyline_odds < 0,
        -away_moneyline_odds / (-away_moneyline_odds + 100.0),
        iff(away_moneyline_odds > 0, 100.0 / (away_moneyline_odds + 100.0), null)
    )                                                               as away_moneyline_implied_probability,
    iff(home_spread_odds < 0,
        -home_spread_odds / (-home_spread_odds + 100.0),
        iff(home_spread_odds > 0, 100.0 / (home_spread_odds + 100.0), null)
    )                                                               as home_spread_implied_probability,
    iff(away_spread_odds < 0,
        -away_spread_odds / (-away_spread_odds + 100.0),
        iff(away_spread_odds > 0, 100.0 / (away_spread_odds + 100.0), null)
    )                                                               as away_spread_implied_probability,
    iff(over_odds < 0,
        -over_odds / (-over_odds + 100.0),
        iff(over_odds > 0, 100.0 / (over_odds + 100.0), null)
    )                                                               as over_implied_probability,
    iff(under_odds < 0,
        -under_odds / (-under_odds + 100.0),
        iff(under_odds > 0, 100.0 / (under_odds + 100.0), null)
    )                                                               as under_implied_probability,
    home_moneyline_implied_probability
        / nullif(home_moneyline_implied_probability + away_moneyline_implied_probability, 0)
                                                                    as home_moneyline_devig_probability,
    away_moneyline_implied_probability
        / nullif(home_moneyline_implied_probability + away_moneyline_implied_probability, 0)
                                                                    as away_moneyline_devig_probability,
    iff(home_spread_odds < 0,
        -home_spread_odds / (-home_spread_odds + 100.0),
        iff(home_spread_odds > 0, 100.0 / (home_spread_odds + 100.0), null)
    )                                                               as home_spread_implied_probability,
    iff(away_spread_odds < 0,
        -away_spread_odds / (-away_spread_odds + 100.0),
        iff(away_spread_odds > 0, 100.0 / (away_spread_odds + 100.0), null)
    )                                                               as away_spread_implied_probability,
    iff(over_odds < 0,
        -over_odds / (-over_odds + 100.0),
        iff(over_odds > 0, 100.0 / (over_odds + 100.0), null)
    )                                                               as over_implied_probability,
    iff(under_odds < 0,
        -under_odds / (-under_odds + 100.0),
        iff(under_odds > 0, 100.0 / (under_odds + 100.0), null)
    )                                                               as under_implied_probability,
    total_line / 2.0 - home_spread / 2.0                             as implied_home_team_total,
    total_line / 2.0 + home_spread / 2.0                             as implied_away_team_total,
    opening_home_spread,
    opening_away_spread,
    opening_home_spread_odds,
    opening_away_spread_odds,
    opening_home_moneyline_odds,
    opening_away_moneyline_odds,
    opening_total_line,
    opening_over_odds,
    opening_under_odds,
    home_spread - opening_home_spread                               as home_spread_movement,
    away_spread - opening_away_spread                               as away_spread_movement,
    home_spread_odds - opening_home_spread_odds                     as home_spread_odds_movement,
    away_spread_odds - opening_away_spread_odds                     as away_spread_odds_movement,
    home_moneyline_odds - opening_home_moneyline_odds               as home_moneyline_odds_movement,
    away_moneyline_odds - opening_away_moneyline_odds               as away_moneyline_odds_movement,
    total_line - opening_total_line                                 as total_line_movement,
    over_odds - opening_over_odds                                   as over_odds_movement,
    under_odds - opening_under_odds                                 as under_odds_movement,
    home_team_score,
    away_team_score,
    iff(is_completed, home_team_score + away_team_score, null)       as actual_total,
    iff(is_completed, home_team_score - away_team_score, null)       as home_point_margin,
    case
        when not is_completed or home_spread is null then null
        when home_team_score - away_team_score + home_spread > 0 then 'cover'
        when home_team_score - away_team_score + home_spread < 0 then 'no cover'
        else 'push'
    end                                                             as home_spread_result,
    case
        when not is_completed or total_line is null then null
        when home_team_score + away_team_score > total_line then 'over'
        when home_team_score + away_team_score < total_line then 'under'
        else 'push'
    end                                                             as total_result,
    dlt_load_id_numeric,
    loaded_at
from joined
