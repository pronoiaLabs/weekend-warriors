{{ config(materialized='table') }}

/*
    Pregame game-line history. Grain: game x vendor x snapshot.

    Every distinct line a book showed before kickoff, in the order it was
    observed: the path from the opening number to the closing one. The opening
    and closing facts are the two ends of this path (closing = snapshot_number
    = snapshots_before_kickoff, the latest observation strictly before
    kickoff, by the same snapshot_observed_at rule fact_game_betting_odds_closing
    uses). Consecutive identical snapshots are collapsed, so a row means the
    line changed, and each row carries the change from the previous one.

    The source keeps SCD2 versions per provider odds id; a snapshot observed at
    or after kickoff is excluded here, as it is from closing.
*/

with eligible as (

    select
        o.game_key,
        o.game_id,
        o.source_odds_id,
        o.vendor,
        o.snapshot_observed_at,
        o.valid_from,
        o.home_spread,
        o.home_spread_odds,
        o.away_spread,
        o.away_spread_odds,
        o.home_moneyline_odds,
        o.away_moneyline_odds,
        o.total_line,
        o.over_odds,
        o.under_odds,
        g.game_datetime,
        g.game_date,
        g.season,
        g.week,
        g.season_type,
        g.season_type_name,
        g.season_week_key,
        g.home_team_key,
        g.away_team_key
    from {{ ref('stg_nfl__odds') }} o
    inner join {{ ref('dim_game') }} g
        on g.game_key = o.game_key
    where o.snapshot_observed_at < g.game_datetime
      and o.vendor is not null

),

ordered as (

    select
        *,
        lag(home_spread)          over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id) as prev_home_spread,
        lag(home_spread_odds)     over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id) as prev_home_spread_odds,
        lag(away_spread_odds)     over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id) as prev_away_spread_odds,
        lag(home_moneyline_odds)  over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id) as prev_home_moneyline_odds,
        lag(away_moneyline_odds)  over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id) as prev_away_moneyline_odds,
        lag(total_line)           over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id) as prev_total_line,
        lag(over_odds)            over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id) as prev_over_odds,
        lag(under_odds)           over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id) as prev_under_odds
    from eligible

),

-- keep the first observation and every one that changed something
changed as (

    select *
    from ordered
    where prev_home_spread is null and prev_total_line is null and prev_home_moneyline_odds is null
       or home_spread is distinct from prev_home_spread
       or home_spread_odds is distinct from prev_home_spread_odds
       or away_spread_odds is distinct from prev_away_spread_odds
       or home_moneyline_odds is distinct from prev_home_moneyline_odds
       or away_moneyline_odds is distinct from prev_away_moneyline_odds
       or total_line is distinct from prev_total_line
       or over_odds is distinct from prev_over_odds
       or under_odds is distinct from prev_under_odds

),

numbered as (

    select
        *,
        row_number() over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id)
                                                        as snapshot_number,
        count(*) over (partition by game_id, vendor)    as snapshots_before_kickoff,
        lag(snapshot_observed_at) over (partition by game_id, vendor order by snapshot_observed_at, valid_from, source_odds_id)
                                                        as prev_snapshot_observed_at
    from changed

)

select
    {{ dbt_utils.generate_surrogate_key(['game_id', 'vendor', 'snapshot_number']) }}
                                                        as game_odds_snapshot_key,
    {{ dbt_utils.generate_surrogate_key(['game_id', 'vendor']) }}
                                                        as game_vendor_odds_key,
    game_key,
    game_id,
    season_week_key,
    home_team_key,
    away_team_key,
    source_odds_id,
    vendor,
    game_datetime,
    game_date,
    season,
    week,
    season_type,
    season_type_name,
    snapshot_number,
    snapshots_before_kickoff,
    snapshot_number = 1                                 as is_opening,
    snapshot_number = snapshots_before_kickoff          as is_closing,
    snapshot_observed_at,
    prev_snapshot_observed_at,
    datediff(minute, snapshot_observed_at, game_datetime)
                                                        as minutes_before_kickoff,
    home_spread,
    home_spread_odds,
    away_spread,
    away_spread_odds,
    home_moneyline_odds,
    away_moneyline_odds,
    total_line,
    over_odds,
    under_odds,
    home_spread - prev_home_spread                      as home_spread_change,
    total_line - prev_total_line                        as total_line_change,
    home_moneyline_odds - prev_home_moneyline_odds      as home_moneyline_odds_change,
    away_moneyline_odds - prev_away_moneyline_odds      as away_moneyline_odds_change
from numbered
