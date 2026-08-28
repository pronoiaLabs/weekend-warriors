{{ config(materialized='semantic_view') }}

/*
    NFL player prop offers at game x player x vendor x prop_type grain.
    Offers and same-vendor line movement are modeled; actual prop outcomes are
    deliberately absent because no verified prop-type-to-box-score map exists.

    Props now carry the Sleeper projection standing at kickoff (one row per
    player x game, latest strictly-pre-kickoff snapshot) so line-vs-projection
    questions are answerable without leaving this view.
*/

tables (
    opening_props as {{ ref('fact_player_prop_opening') }}
        primary key (game_player_vendor_prop_key)
        with synonyms ('opening player lines', 'prop openers')
        comment = 'One opening offer per game, player, vendor and prop type.',

    closing_props as {{ ref('fact_player_prop_closing') }}
        primary key (game_player_vendor_prop_key)
        with synonyms ('closing player lines', 'pregame props')
        comment = 'Latest prop snapshot observed strictly before kickoff, with same-vendor opening values and movement.',

    projections as {{ ref('fact_sleeper_projection_latest') }}
        primary key (player_key, game_key)
        with synonyms ('projections', 'sleeper projections', 'projected stats')
        comment = 'The Sleeper projection standing at kickoff: one row per player and game, the latest strictly-pre-kickoff snapshot only.',

    players as {{ ref('dim_player') }}
        primary key (player_key)
        comment = 'NFL player identity and position.',

    games as {{ ref('dim_game') }}
        primary key (game_key)
        comment = 'Game date, season, week and teams.',

    home_teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'Home team role for the prop game.',

    away_teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'Away team role for the prop game.'
)

relationships (
    closing_to_opening as closing_props (game_player_vendor_prop_key) references opening_props (game_player_vendor_prop_key),
    closing_to_player as closing_props (player_key) references players (player_key),
    closing_to_game as closing_props (game_key) references games (game_key),
    closing_to_home_team as closing_props (home_team_key) references home_teams (team_key),
    closing_to_away_team as closing_props (away_team_key) references away_teams (team_key),
    -- closing_props is the hub and the graph is deliberately a tree:
    -- opening_props and projections hang off it, and neither carries its own
    -- edges to the dims. Duplicate edges would give every dimension two paths
    -- from a fact, and SEMANTIC_VIEW() rejects multi-path dimension
    -- resolution outright (measured 2026-08-28). Opening context is not lost:
    -- the closing fact itself carries opening_line_value and the movement
    -- columns.
    closing_to_projection as closing_props (player_key, game_key) references projections (player_key, game_key)
)

facts (
    opening_props.line_value as line_value comment = 'Opening offered prop line.',
    opening_props.market_odds as market_odds comment = 'Opening generic American market odds when supplied.',
    opening_props.over_odds as over_odds comment = 'Opening American odds for the over side.',
    opening_props.under_odds as under_odds comment = 'Opening American odds for the under side.',
    closing_props.line_value as line_value comment = 'Closing offered prop line, selected strictly before kickoff.',
    closing_props.market_odds as market_odds comment = 'Closing generic American market odds when supplied.',
    closing_props.over_odds as over_odds comment = 'Closing American odds for the over side.',
    closing_props.under_odds as under_odds comment = 'Closing American odds for the under side.',
    closing_props.opening_line_value as opening_line_value
        comment = 'Same-vendor opening line carried onto the closing row.',
    closing_props.line_movement as line_movement
        comment = 'Closing line minus same-vendor opening line.',
    closing_props.over_odds_movement as over_odds_movement
        comment = 'Closing over odds minus opening over odds.',
    closing_props.under_odds_movement as under_odds_movement
        comment = 'Closing under odds minus opening under odds.',
    projections.projected_pts_ppr as pts_ppr
        with synonyms ('projected ppr points', 'projected fantasy points')
        comment = 'Sleeper projected fantasy points, PPR scoring.',
    projections.projected_pts_half_ppr as pts_half_ppr
        with synonyms ('projected half ppr points')
        comment = 'Sleeper projected fantasy points, half-PPR scoring.',
    projections.projected_pts_std as pts_std
        with synonyms ('projected standard points')
        comment = 'Sleeper projected fantasy points, standard scoring.',
    projections.projected_targets as rec_tgt
        comment = 'Sleeper projected receiving targets.',
    projections.projected_receptions as rec
        with synonyms ('projected catches')
        comment = 'Sleeper projected receptions.',
    projections.projected_receiving_yards as rec_yd
        comment = 'Sleeper projected receiving yards.',
    projections.projected_receiving_tds as rec_td
        comment = 'Sleeper projected receiving touchdowns.',
    projections.projected_rush_attempts as rush_att
        with synonyms ('projected carries')
        comment = 'Sleeper projected rushing attempts.',
    projections.projected_rushing_yards as rush_yd
        comment = 'Sleeper projected rushing yards.',
    projections.projected_rushing_tds as rush_td
        comment = 'Sleeper projected rushing touchdowns.',
    projections.projected_pass_attempts as pass_att
        comment = 'Sleeper projected pass attempts.',
    projections.projected_passing_yards as pass_yd
        comment = 'Sleeper projected passing yards.',
    projections.projected_passing_tds as pass_td
        comment = 'Sleeper projected passing touchdowns.',
    projections.projected_interceptions as pass_int
        comment = 'Sleeper projected interceptions thrown.',
    projections.projection_move as pts_ppr_change
        with synonyms ('projection movement')
        comment = 'PPR movement vs the prior snapshot.'
)

dimensions (
    players.full_name as full_name
        with synonyms ('player', 'player name')
        comment = 'Player full name.',
    players.position_name as position_name
        comment = 'Normalized player position.',
    players.gsis_id as gsis_id
        comment = 'nflverse player id. Join key for pairing a closing line subquery with a projection subquery.',
    closing_props.vendor as vendor
        comment = 'Sportsbook vendor. Vendor is part of the grain.'
        ,
    closing_props.prop_type as prop_type
        with synonyms ('market', 'player market')
        comment = 'Provider prop category, normalized to lowercase.',
    closing_props.market_type as market_type
        comment = 'Provider market-side/type label when supplied.',
    closing_props.line_timing as line_timing
        comment = 'Always closing for closing_props; selected strictly before kickoff.'
        sample_values ('closing') is_enum,
    opening_props.line_timing as line_timing
        comment = 'Always opening for opening_props.'
        sample_values ('opening') is_enum,
    closing_props.selected_snapshot_at as selected_snapshot_at
        comment = 'Timestamp of the chosen strictly pre-kickoff snapshot.',
    closing_props.outcome_evaluation_status as outcome_evaluation_status
        comment = 'Explicitly states that actual prop result grading is not modeled.',
    games.game_date as game_date comment = 'Game calendar date.',
    games.season as season comment = 'NFL season year.',
    games.week as week comment = 'Week within the season phase.',
    games.season_type_name as season_type_name
        comment = 'Preseason, Regular Season, or Postseason.'
        sample_values ('Preseason', 'Regular Season', 'Postseason') is_enum,
    home_teams.home_team_name as team_full_name comment = 'Home team full name.',
    away_teams.away_team_name as team_full_name comment = 'Away team full name.',
    projections.projection_as_of as projection_as_of
        with synonyms ('projection timestamp', 'projection fetched at')
        comment = 'When the standing projection was fetched.',
    projections.adp_dd_ppr as adp_dd_ppr
        with synonyms ('adp', 'average draft position')
        comment = 'Draft-season ADP context, overall.',
    projections.pos_adp_dd_ppr as pos_adp_dd_ppr
        with synonyms ('positional adp')
        comment = 'Draft-season ADP context, positional.',
    projections.projection_gsis_id as gsis_id
        comment = 'nflverse player id on the projection row. Join key for pairing with the closing line subquery.',
    projections.projection_season as season
        comment = 'Season on the projection row; join key beside projection_gsis_id and projection_week.',
    projections.projection_week as week
        comment = 'Week on the projection row (Sleeper numbering; postseason restarts at 1).',
    projections.projection_season_type as season_type
        comment = 'Sleeper season phase on the projection row: regular, post or pre. Filter it to match the props side (Regular Season pairs with regular) so preseason week numbers never collide with regular season weeks.'
        sample_values ('regular', 'post', 'pre') is_enum
)

metrics (
    closing_props.offer_count as count(closing_props.game_player_vendor_prop_key)
        comment = 'Number of player prop offers at closing grain.',
    closing_props.avg_line as avg(closing_props.line_value)
        comment = 'Average offered closing line; use only within one prop type.',
    closing_props.avg_line_movement as avg(closing_props.line_movement)
        comment = 'Average closing-minus-opening movement; use only within one prop type.',
    -- The projections entity has exactly one row per player and game, so each
    -- avg below IS the standing projection. They exist as metrics because a
    -- SEMANTIC_VIEW query cannot mix FACTS with DIMENSIONS across entities;
    -- grouped by the projections entity's own dimensions they give the
    -- projection side of a projection-versus-line join.
    projections.avg_projected_receiving_yards as avg(projections.rec_yd)
        comment = 'The standing projected receiving yards (one row per player-game).',
    projections.avg_projected_receptions as avg(projections.rec)
        comment = 'The standing projected receptions.',
    projections.avg_projected_rushing_yards as avg(projections.rush_yd)
        comment = 'The standing projected rushing yards.',
    projections.avg_projected_passing_yards as avg(projections.pass_yd)
        comment = 'The standing projected passing yards.',
    projections.avg_projected_passing_tds as avg(projections.pass_td)
        comment = 'The standing projected passing touchdowns.',
    projections.avg_projected_pts_ppr as avg(projections.pts_ppr)
        comment = 'The standing projected PPR points.'
)

comment = 'NFL player prop offers by game, player, sportsbook vendor and prop type. Supports opening and strictly pre-kickoff closing lines, American odds and same-vendor movement, and now carries the Sleeper projection standing at kickoff for line-vs-projection questions. It deliberately does not grade actual prop outcomes because the provider prop taxonomy has not been safely mapped to box-score measures.'

ai_sql_generation 'VENDOR AND PROP TYPE ARE PART OF THE GRAIN: always show or filter both. Never average unlike prop types.
LINE TIMING IS EXPLICIT: opening_props are opening offers; closing_props are the latest observations strictly before kickoff. There are no live or post-kickoff odds.
MOVEMENT: line_movement is closing minus opening for the same game, player, vendor and prop type.
NO OUTCOME CLAIMS: this view does not map prop types to box-score results. Do not say a player went over, under, won or lost a prop.
DEFAULT PHASE: default to Regular Season unless the user requests another phase.
NAME COLLISIONS: if a player name is ambiguous, use position and ask the user to disambiguate.
PROP TYPE TO PROJECTION MAP: receiving_yards -> projected_receiving_yards; receptions -> projected_receptions; rushing_yards -> projected_rushing_yards; passing_yards -> projected_passing_yards; passing_tds -> projected_passing_tds. Every anytime_td, first_td, quarter or half td prop type has NO projection equivalent; never substitute one.
PROJECTIONS ARE PRE-SELECTED: the projections table already holds only the latest strictly-pre-kickoff snapshot per player and game; never aggregate multiple snapshots. Rows may be absent (NULL after the join) when Sleeper published no projection; NULL means no projection, never zero and never evidence the line is right.
PROJECTION VS LINE: compare by subtracting the closing line value from the mapped projected column, within one vendor and one prop_type.
QUERY SHAPE: a SEMANTIC_VIEW query cannot mix FACTS and DIMENSIONS from different logical tables. To place a projection beside an offered line, run two SEMANTIC_VIEW subqueries and join them in the outer query on gsis id, season and week: closing metrics (avg_line) grouped by players.gsis_id, games.season and games.week on one side, and the projections avg_projected metrics grouped by projection_gsis_id, projection_season and projection_week on the other, filtering the projection side to the matching projection_season_type (regular for Regular Season), as the verified queries demonstrate.'

ai_question_categorization 'Answer questions about NFL individual-player sportsbook lines, offered prop types, vendors, opening versus closing values, and pregame line movement.
If the question asks about team spreads, team moneylines, game totals or ATS results, route it to NFLGameOddsAnalytics.
If the question asks whether a player actually went over or under, say outcome grading is not available; offer the listed line and movement instead.
If the question asks for live or in-game props, say they are unavailable.
Questions about projected stats or projection-versus-line divergence are in scope here; season-long fantasy advice beyond these weekly projections is not.'

ai_verified_queries (
    player_prop_movement as (
        question 'How did Christian McCaffrey prop lines move from opening to closing by sportsbook?'
        verified_at 1786233600
        onboarding_question true
        sql 'SELECT full_name, vendor, prop_type, game_date,
                    avg_line, avg_line_movement
             FROM SEMANTIC_VIEW({{ this }}
               METRICS closing_props.avg_line, closing_props.avg_line_movement
               DIMENSIONS players.full_name, closing_props.vendor,
                          closing_props.prop_type, games.game_date)
             WHERE full_name = ''Christian McCaffrey''
             ORDER BY game_date DESC, prop_type, vendor'
    ),
    projection_vs_line_screen as (
        question 'Where does the Sleeper projection diverge most from the closing receiving yards line this week?'
        verified_at 1787788800
        sql 'SELECT l.full_name, l.vendor, l.line_value,
                    p.projected_receiving_yards,
                    p.projected_receiving_yards - l.line_value AS projection_edge
             FROM (SELECT full_name, gsis_id, vendor, season, week,
                          avg_line AS line_value
                   FROM SEMANTIC_VIEW({{ this }}
                     METRICS closing_props.avg_line
                     DIMENSIONS players.full_name, players.gsis_id,
                                closing_props.vendor, closing_props.prop_type,
                                games.season, games.week,
                                games.season_type_name)
                   WHERE prop_type = ''receiving_yards''
                     AND season = 2026 AND week = 1
                     AND season_type_name = ''Regular Season'') l
             JOIN (SELECT projection_gsis_id, projection_season,
                          projection_week,
                          avg_projected_receiving_yards
                              AS projected_receiving_yards
                   FROM SEMANTIC_VIEW({{ this }}
                     METRICS projections.avg_projected_receiving_yards
                     DIMENSIONS projections.projection_gsis_id,
                                projections.projection_season,
                                projections.projection_week,
                                projections.projection_season_type)
                   WHERE projection_season_type = ''regular'') p
               ON p.projection_gsis_id = l.gsis_id
              AND p.projection_season = l.season
              AND p.projection_week = l.week
             ORDER BY projection_edge DESC'
    ),
    projection_for_player as (
        question 'What closing prop lines are offered on Christian McCaffrey and what does Sleeper project for him?'
        verified_at 1787788800
        sql 'SELECT l.full_name, l.season, l.week, l.prop_type, l.vendor,
                    l.line_value, p.projected_passing_yards,
                    p.projected_passing_tds, p.projected_receiving_yards,
                    p.projected_receptions, p.projected_rushing_yards
             FROM (SELECT full_name, gsis_id, season, week, prop_type, vendor,
                          avg_line AS line_value
                   FROM SEMANTIC_VIEW({{ this }}
                     METRICS closing_props.avg_line
                     DIMENSIONS players.full_name, players.gsis_id,
                                closing_props.prop_type, closing_props.vendor,
                                games.season, games.week)
                   WHERE full_name = ''Christian McCaffrey'') l
             JOIN (SELECT projection_gsis_id, projection_season,
                          projection_week,
                          avg_projected_passing_yards
                              AS projected_passing_yards,
                          avg_projected_passing_tds AS projected_passing_tds,
                          avg_projected_receiving_yards
                              AS projected_receiving_yards,
                          avg_projected_receptions AS projected_receptions,
                          avg_projected_rushing_yards
                              AS projected_rushing_yards
                   FROM SEMANTIC_VIEW({{ this }}
                     METRICS projections.avg_projected_passing_yards,
                             projections.avg_projected_passing_tds,
                             projections.avg_projected_receiving_yards,
                             projections.avg_projected_receptions,
                             projections.avg_projected_rushing_yards
                     DIMENSIONS projections.projection_gsis_id,
                                projections.projection_season,
                                projections.projection_week,
                                projections.projection_season_type)
                   WHERE projection_season_type = ''regular'') p
               ON p.projection_gsis_id = l.gsis_id
              AND p.projection_season = l.season
              AND p.projection_week = l.week
             ORDER BY l.season DESC, l.week DESC, l.prop_type, l.vendor'
    )
)
