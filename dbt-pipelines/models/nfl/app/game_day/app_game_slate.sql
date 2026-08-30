/*
    app_game_slate -- the game day board, one row per game x sportsbook.
    Grain: game x vendor. Games with no closing line keep one row with vendor
    NULL, so every game on dim_game appears at least once. Key: app_game_slate_key.

    APP is the serving layer for the analytics dashboard: page-shaped marts built
    from CORE, read by a thin API with bound filters. Long format, parameters as
    columns (season, week, season_type, vendor) so the API filters rather than
    dbt precomputing per choice. Not a Cortex tool; no semantic view sits on it.

    What is joined, and from where:
      teams, stadium         dim_team (role-played twice), dim_stadium via dim_game.stadium_key
                             (NULL when the feed's venue string is not in seed_nfl_stadiums)
      forecast               fact_game_weather_forecast, one row per game, LEFT joined because
                             it is INNER-built and a game with no stadium or no weather hour
                             is absent from it
      closing line           fact_game_betting_odds_closing, one row per vendor; the fan-out
      score                  fact_team_game_offense home row (points_scored / points_allowed),
                             independent of whether a line exists
      readiness              props_open counts fact_player_prop_closing rows for the same
                             game and vendor; news_mentions_7d counts resolved mentions whose
                             team is either side, published in the seven days before the game
      records                fact_team_game_offense rows strictly before this game's date,
                             same season and season type -- the record ENTERING the game,
                             which for an unplayed game is the season to date. Postseason
                             games show the regular-season record (the conventional "12-5").
      availability           fact_injury_report is already anchored to this game_key, so the
                             counters are a straight count of Out / Questionable filings per
                             side. NULL means no nflverse coverage for the game (preseason),
                             0 means a clean report; the feed's 'Doubtful' and 'Note' rows
                             sit in neither counter.
      referee, division      dim_game passthroughs -- the head official (NULL = no nflverse
                             coverage, never a placeholder) and its is_division_game.

    Kickoff slot is a display string ('Sun 1:00 PM') derived once here so every
    page groups the same way. Eastern time, the feed's game_datetime_et.
    kickoff_window is the named ledger grouping (TNF / SUN_EARLY / ... ) with a
    label and a chronological sort order; INTL wins over the temporal bucket so a
    London 9:30 AM game does not read as Sunday Early, and rows whose kickoff is
    date-only (hour 0, the feed's TBD form) fall to OTHER rather than lying.

    Every column added for the ledger is game-level, so it rides the vendor-NULL
    row by construction.
*/

with games as (

    select * from {{ ref('dim_game') }}

),

teams as (

    select * from {{ ref('dim_team') }}

),

stadiums as (

    select * from {{ ref('dim_stadium') }}

),

forecast as (

    select * from {{ ref('fact_game_weather_forecast') }}

),

odds as (

    select * from {{ ref('fact_game_betting_odds_closing') }}

),

scores as (

    select
        game_key,
        points_scored   as home_score,
        points_allowed  as away_score
    from {{ ref('fact_team_game_offense') }}
    where is_home

),

props_by_vendor as (

    select
        game_key,
        vendor,
        count(*)                    as props_open,
        count(distinct player_key)  as players_with_props
    from {{ ref('fact_player_prop_closing') }}
    group by 1, 2

),

props_all_books as (

    select
        game_key,
        count(*)                    as props_open_all_books,
        count(distinct player_key)  as players_with_props_all_books
    from {{ ref('fact_player_prop_closing') }}
    group by 1

),

-- the record entering the game: completed rows strictly before this game's date.
-- A playoff game shows the regular-season record; week 1 is honestly 0-0.
records as (

    select
        g.game_key,
        tg.team_key,
        sum(tg.win_count)                               as wins,
        sum(tg.loss_count)                              as losses,
        sum(tg.tie_count)                               as ties
    from games g
    inner join {{ ref('fact_team_game_offense') }} tg
        on tg.season = g.season
       and tg.team_key in (g.home_team_key, g.away_team_key)
       and iff(g.is_postseason,
               tg.season_type = 2,
               tg.season_type = g.season_type and tg.game_date < g.game_date)
    group by 1, 2

),

-- Out / Questionable filings for this game, per side. The fact carries the
-- game_key already; all filed rows count, bridged or not.
injuries as (

    select
        game_key,
        team_key,
        count_if(report_status = 'Out')                 as players_out,
        count_if(report_status = 'Questionable')        as players_questionable
    from {{ ref('fact_injury_report') }}
    where game_key is not null
      and team_key is not null
    group by 1, 2

),

news as (

    select
        g.game_key,
        count(*)                    as news_mentions_7d,
        count(distinct n.player_key) as players_in_news_7d
    from games g
    inner join {{ ref('fact_player_news_mention') }} n
        on n.mention_team_key in (g.home_team_key, g.away_team_key)
       and n.published_date between dateadd(day, -7, g.game_date) and g.game_date
       and n.player_key is not null
    group by 1

),

-- the fan-out: one row per game and vendor, or one row with vendor NULL
game_vendor as (

    select
        g.game_key,
        o.vendor,
        o.game_vendor_odds_key
    from games g
    left join odds o
        on o.game_key = g.game_key

)

select
    {{ dbt_utils.generate_surrogate_key(['gv.game_key', "coalesce(gv.vendor, 'none')"]) }}
                                                        as app_game_slate_key,
    g.game_key,
    g.game_id,

    -- when
    g.season,
    g.week,
    g.season_type,
    g.season_type_name,
    g.is_postseason,
    g.season_week_key,
    g.game_date,
    g.game_datetime,
    g.game_datetime_et,
    regexp_replace(to_char(g.game_datetime_et, 'DY HH12:MI AM'), ' 0', ' ')
                                                        as kickoff_slot_et,
    case
        when hour(g.game_datetime_et) = 0                                   then 'OTHER'
        when coalesce(s.is_international, false)                            then 'INTL'
        when dayname(g.game_datetime_et) = 'Thu'                            then 'TNF'
        when dayname(g.game_datetime_et) = 'Fri'                            then 'FRI'
        when dayname(g.game_datetime_et) = 'Sat'                            then 'SAT'
        when dayname(g.game_datetime_et) = 'Sun'
         and hour(g.game_datetime_et) < 15                                  then 'SUN_EARLY'
        when dayname(g.game_datetime_et) = 'Sun'
         and hour(g.game_datetime_et) < 19                                  then 'SUN_LATE'
        when dayname(g.game_datetime_et) = 'Sun'                            then 'SNF'
        when dayname(g.game_datetime_et) = 'Mon'                            then 'MNF'
        else 'OTHER'
    end                                                 as kickoff_window,
    decode(kickoff_window,
        'TNF', 'Thursday Night', 'FRI', 'Friday', 'SAT', 'Saturday',
        'INTL', 'International', 'SUN_EARLY', 'Sunday Early', 'SUN_LATE', 'Sunday Late',
        'SNF', 'Sunday Night', 'MNF', 'Monday Night', 'Other')
                                                        as kickoff_window_label,
    decode(kickoff_window,
        'TNF', 1, 'FRI', 2, 'SAT', 3, 'INTL', 4, 'SUN_EARLY', 5,
        'SUN_LATE', 6, 'SNF', 7, 'MNF', 8, 9)           as kickoff_window_order,
    g.game_status,
    g.is_completed,
    g.went_to_overtime,
    g.is_division_game,
    g.referee,

    -- who
    g.home_team_key,
    g.home_team_id,
    h.team_abbreviation                                 as home_team_label,
    h.team_full_name                                    as home_team_name,
    h.conference                                        as home_conference,
    h.division                                          as home_division,
    g.away_team_key,
    g.away_team_id,
    a.team_abbreviation                                 as away_team_label,
    a.team_full_name                                    as away_team_name,
    a.conference                                        as away_conference,
    a.division                                          as away_division,

    -- the record entering the game (0-0 at week 1)
    coalesce(rh.wins, 0)                                as home_wins,
    coalesce(rh.losses, 0)                              as home_losses,
    coalesce(rh.ties, 0)                                as home_ties,
    coalesce(rh.wins, 0) || '-' || coalesce(rh.losses, 0)
        || iff(coalesce(rh.ties, 0) > 0, '-' || rh.ties, '')
                                                        as home_record,
    coalesce(ra.wins, 0)                                as away_wins,
    coalesce(ra.losses, 0)                              as away_losses,
    coalesce(ra.ties, 0)                                as away_ties,
    coalesce(ra.wins, 0) || '-' || coalesce(ra.losses, 0)
        || iff(coalesce(ra.ties, 0) > 0, '-' || ra.ties, '')
                                                        as away_record,

    -- availability: NULL = no nflverse report coverage (preseason), 0 = clean report
    iff(g.nflverse_game_id is null, null, coalesce(inj_h.players_out, 0))
                                                        as home_players_out,
    iff(g.nflverse_game_id is null, null, coalesce(inj_h.players_questionable, 0))
                                                        as home_players_questionable,
    iff(g.nflverse_game_id is null, null, coalesce(inj_a.players_out, 0))
                                                        as away_players_out,
    iff(g.nflverse_game_id is null, null, coalesce(inj_a.players_questionable, 0))
                                                        as away_players_questionable,

    -- where
    g.venue,
    g.stadium_key,
    s.display_name                                      as stadium_name,
    s.roof,
    s.surface,
    s.is_weather_relevant,
    s.is_international,

    -- forecast
    f.kickoff_temp_f,
    f.wind_mph,
    f.gust_mph,
    f.wind_dir_deg,
    f.precip_in,
    f.weather_code,
    f.hours_before_kickoff                              as forecast_hours_before_kickoff,

    -- the closing line at this book
    gv.vendor,
    gv.game_vendor_odds_key,
    o.home_spread,
    o.away_spread,
    o.home_spread_odds,
    o.away_spread_odds,
    o.total_line,
    o.over_odds,
    o.under_odds,
    o.home_moneyline_odds,
    o.away_moneyline_odds,
    o.opening_home_spread,
    o.opening_total_line,
    o.home_spread_movement,
    o.total_line_movement,
    o.implied_home_team_total,
    o.implied_away_team_total,
    o.home_moneyline_devig_probability,
    o.away_moneyline_devig_probability,
    o.selected_snapshot_at                              as line_selected_at,
    o.home_spread_result,
    o.total_result,

    -- result, when played
    sc.home_score,
    sc.away_score,

    -- readiness for the prop board
    coalesce(pv.props_open, 0)                          as props_open,
    coalesce(pv.players_with_props, 0)                  as players_with_props,
    coalesce(pa.props_open_all_books, 0)                as props_open_all_books,
    coalesce(pa.players_with_props_all_books, 0)        as players_with_props_all_books,
    coalesce(n.news_mentions_7d, 0)                     as news_mentions_7d,
    coalesce(n.players_in_news_7d, 0)                   as players_in_news_7d

from game_vendor gv
inner join games g
    on g.game_key = gv.game_key
left join teams h
    on h.team_key = g.home_team_key
left join teams a
    on a.team_key = g.away_team_key
left join stadiums s
    on s.stadium_key = g.stadium_key
left join forecast f
    on f.game_key = g.game_key
left join odds o
    on o.game_vendor_odds_key = gv.game_vendor_odds_key
left join scores sc
    on sc.game_key = g.game_key
left join props_by_vendor pv
    on pv.game_key = g.game_key
   and pv.vendor = gv.vendor
left join props_all_books pa
    on pa.game_key = g.game_key
left join news n
    on n.game_key = g.game_key
left join records rh
    on rh.game_key = g.game_key
   and rh.team_key = g.home_team_key
left join records ra
    on ra.game_key = g.game_key
   and ra.team_key = g.away_team_key
left join injuries inj_h
    on inj_h.game_key = g.game_key
   and inj_h.team_key = g.home_team_key
left join injuries inj_a
    on inj_a.game_key = g.game_key
   and inj_a.team_key = g.away_team_key
