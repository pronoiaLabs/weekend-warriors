{{
    config(
        materialized='table'
    )
}}

/*
    app_market_movers -- the Pulse's movers zone: what the books have repriced
    since open, game lines and player props in one mart.

    Grain: two kinds under one key, discriminated by `kind`:

      game  game x vendor x market (market in 'spread', 'total') -- the
            opening snapshot joined to the latest pregame snapshot on
            fact_game_betting_odds_snapshot. Spread lines are HOME-SIDED:
            open_line/latest_line are the home spread, and the page renders
            the sided label from the team columns.
      prop  game x player x vendor x prop_type -- the same open-to-latest join
            on fact_player_prop_snapshot; market carries the prop_type.

    A row means the line MOVED: the snapshot facts collapse identical
    observations, and rows where delta = 0 (single-snapshot series) are
    dropped -- same doctrine as app_line_history. Kind-specific identity
    columns are NULL on the other kind, in the vendor-NULL "NULL means not
    applicable" spirit.

    mover_rank pre-ranks by abs(delta) within (season, season_type, week,
    vendor, kind) so the API takes top-N with a bound filter and a limit, no
    aggregation. Prop identity (name, team, stat label) comes from
    app_game_prop_board (app-reads-app, the app_team_ats precedent), which
    shares the snapshot facts' key.
*/

with game_open as (

    select * from {{ ref('fact_game_betting_odds_snapshot') }} where is_opening

),

game_latest as (

    select * from {{ ref('fact_game_betting_odds_snapshot') }} where is_closing

),

game_pairs as (

    select
        o.game_vendor_odds_key,
        o.game_key,
        o.game_id,
        o.season,
        o.week,
        o.season_type,
        o.season_type_name,
        o.game_date,
        o.game_datetime,
        o.vendor,
        o.home_team_key,
        o.away_team_key,
        o.snapshot_observed_at                          as open_at,
        c.snapshot_observed_at                          as moved_at,
        c.snapshots_before_kickoff                      as snapshots,
        o.home_spread                                   as open_home_spread,
        c.home_spread                                   as latest_home_spread,
        o.total_line                                    as open_total_line,
        c.total_line                                    as latest_total_line
    from game_open o
    inner join game_latest c
        on c.game_vendor_odds_key = o.game_vendor_odds_key

),

game_movers as (

    select *, 'spread' as market, open_home_spread as open_line, latest_home_spread as latest_line
    from game_pairs

    union all

    select *, 'total' as market, open_total_line as open_line, latest_total_line as latest_line
    from game_pairs

),

prop_open as (

    select * from {{ ref('fact_player_prop_snapshot') }} where is_opening

),

prop_latest as (

    select * from {{ ref('fact_player_prop_snapshot') }} where is_closing

),

-- identity at exactly the snapshot facts' series key; the board's grain
prop_identity as (

    select
        game_player_vendor_prop_key,
        player_name,
        position,
        team_key,
        team_label,
        stat_label
    from {{ ref('app_game_prop_board') }}

),

prop_movers as (

    select
        o.game_player_vendor_prop_key,
        o.game_key,
        o.game_id,
        o.season,
        o.week,
        o.season_type,
        o.season_type_name,
        o.game_date,
        o.game_datetime,
        o.vendor,
        o.home_team_key,
        o.away_team_key,
        o.player_key,
        o.player_id,
        o.prop_type,
        o.snapshot_observed_at                          as open_at,
        c.snapshot_observed_at                          as moved_at,
        c.snapshots_before_kickoff                      as snapshots,
        o.line_value                                    as open_line,
        c.line_value                                    as latest_line
    from prop_open o
    inner join prop_latest c
        on c.game_player_vendor_prop_key = o.game_player_vendor_prop_key

),

unioned as (

    select
        {{ dbt_utils.generate_surrogate_key(["'game'", 'game_vendor_odds_key', 'market']) }}
                                                        as app_market_movers_key,
        'game'                                          as kind,
        game_vendor_odds_key                            as series_key,
        game_key,
        game_id,
        season,
        week,
        season_type,
        season_type_name,
        game_date,
        game_datetime,
        vendor,
        market,
        home_team_key,
        away_team_key,
        cast(null as varchar)                           as player_key,
        cast(null as number)                            as player_id,
        cast(null as varchar)                           as team_key,
        cast(null as varchar)                           as stat_label,
        open_line,
        latest_line,
        open_at,
        moved_at,
        snapshots
    from game_movers

    union all

    select
        {{ dbt_utils.generate_surrogate_key(["'prop'", 'game_player_vendor_prop_key']) }}
                                                        as app_market_movers_key,
        'prop'                                          as kind,
        game_player_vendor_prop_key                     as series_key,
        game_key,
        game_id,
        season,
        week,
        season_type,
        season_type_name,
        game_date,
        game_datetime,
        vendor,
        prop_type                                       as market,
        home_team_key,
        away_team_key,
        player_key,
        player_id,
        cast(null as varchar)                           as team_key,
        cast(null as varchar)                           as stat_label,
        open_line,
        latest_line,
        open_at,
        moved_at,
        snapshots
    from prop_movers

)

select
    u.app_market_movers_key,
    u.kind,
    u.game_key,
    u.game_id,
    u.season,
    u.week,
    u.season_type,
    u.season_type_name,
    u.game_date,
    g.game_datetime_et,
    u.vendor,
    u.market,
    u.home_team_key,
    ht.team_abbreviation                                as home_team_label,
    u.away_team_key,
    aw.team_abbreviation                                as away_team_label,
    u.player_key,
    u.player_id,
    coalesce(pi.player_name, p.full_name)               as player_name,
    coalesce(pi.position, p.position_abbreviation)      as position,
    p.headshot_url,
    coalesce(pi.team_key, u.team_key)                   as team_key,
    pi.team_label,
    coalesce(pi.stat_label, u.market)                   as stat_label,
    u.open_line,
    u.latest_line,
    u.latest_line - u.open_line                         as delta,
    abs(u.latest_line - u.open_line)                    as abs_delta,
    u.open_at,
    u.moved_at,
    u.snapshots,
    rank() over (
        partition by u.season, u.season_type, u.week, u.vendor, u.kind
        order by abs(u.latest_line - u.open_line) desc, u.app_market_movers_key
    )                                                   as mover_rank
from unioned u
inner join {{ ref('dim_game') }} g
    on g.game_key = u.game_key
left join {{ ref('dim_team') }} ht
    on ht.team_key = u.home_team_key
left join {{ ref('dim_team') }} aw
    on aw.team_key = u.away_team_key
left join {{ ref('dim_player') }} p
    on p.player_key = u.player_key
left join prop_identity pi
    on u.kind = 'prop'
   and pi.game_player_vendor_prop_key = u.series_key
where u.latest_line is distinct from u.open_line
  and u.open_line is not null
  and u.latest_line is not null
