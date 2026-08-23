{{ config(materialized='table') }}

/*
    Pregame player-prop history. Grain: game x player x vendor x prop type x snapshot.

    The path each prop took from its first observation to the closing line,
    consecutive identical snapshots collapsed so a row means something moved.
    Same pregame rule as fact_player_prop_closing (observed strictly before
    kickoff); the last snapshot here is that fact's row.
*/

with eligible as (

    select
        p.game_key,
        p.game_id,
        p.player_key,
        p.player_id,
        p.source_prop_id,
        p.vendor,
        p.prop_type,
        p.market_type,
        p.snapshot_observed_at,
        p.valid_from,
        p.line_value,
        p.market_odds,
        p.over_odds,
        p.under_odds,
        g.game_datetime,
        g.game_date,
        g.season,
        g.week,
        g.season_type,
        g.season_type_name,
        g.season_week_key,
        g.home_team_key,
        g.away_team_key
    from {{ ref('stg_nfl__player_props') }} p
    inner join {{ ref('dim_game') }} g
        on g.game_key = p.game_key
    where p.snapshot_observed_at < g.game_datetime
      and p.vendor is not null
      and p.prop_type is not null

),

ordered as (

    select
        *,
        lag(line_value)  over (partition by game_id, player_id, vendor, prop_type order by snapshot_observed_at, valid_from, source_prop_id) as prev_line_value,
        lag(market_odds) over (partition by game_id, player_id, vendor, prop_type order by snapshot_observed_at, valid_from, source_prop_id) as prev_market_odds,
        lag(over_odds)   over (partition by game_id, player_id, vendor, prop_type order by snapshot_observed_at, valid_from, source_prop_id) as prev_over_odds,
        lag(under_odds)  over (partition by game_id, player_id, vendor, prop_type order by snapshot_observed_at, valid_from, source_prop_id) as prev_under_odds,
        row_number()     over (partition by game_id, player_id, vendor, prop_type order by snapshot_observed_at, valid_from, source_prop_id) as raw_number
    from eligible

),

changed as (

    select *
    from ordered
    where raw_number = 1
       or line_value is distinct from prev_line_value
       or market_odds is distinct from prev_market_odds
       or over_odds is distinct from prev_over_odds
       or under_odds is distinct from prev_under_odds

),

numbered as (

    select
        *,
        row_number() over (partition by game_id, player_id, vendor, prop_type order by snapshot_observed_at, valid_from, source_prop_id)
                                                        as snapshot_number,
        count(*) over (partition by game_id, player_id, vendor, prop_type)
                                                        as snapshots_before_kickoff,
        lag(snapshot_observed_at) over (partition by game_id, player_id, vendor, prop_type order by snapshot_observed_at, valid_from, source_prop_id)
                                                        as prev_snapshot_observed_at
    from changed

)

select
    {{ dbt_utils.generate_surrogate_key(['game_id', 'player_id', 'vendor', 'prop_type', 'snapshot_number']) }}
                                                        as player_prop_snapshot_key,
    {{ dbt_utils.generate_surrogate_key(['game_id', 'player_id', 'vendor', 'prop_type']) }}
                                                        as game_player_vendor_prop_key,
    game_key,
    game_id,
    player_key,
    player_id,
    season_week_key,
    home_team_key,
    away_team_key,
    source_prop_id,
    vendor,
    prop_type,
    market_type,
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
    line_value,
    market_odds,
    over_odds,
    under_odds,
    line_value - prev_line_value                        as line_value_change,
    market_odds - prev_market_odds                      as market_odds_change,
    over_odds - prev_over_odds                          as over_odds_change,
    under_odds - prev_under_odds                        as under_odds_change
from numbered
