{{ config(materialized='semantic_view') }}

/*
    NFL player prop offers at game x player x vendor x prop_type grain.
    Offers and same-vendor line movement are modeled; actual prop outcomes are
    deliberately absent because no verified prop-type-to-box-score map exists.
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
    opening_to_player as opening_props (player_key) references players (player_key),
    opening_to_game as opening_props (game_key) references games (game_key),
    opening_to_home_team as opening_props (home_team_key) references home_teams (team_key),
    opening_to_away_team as opening_props (away_team_key) references away_teams (team_key)
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
        comment = 'Closing under odds minus opening under odds.'
)

dimensions (
    players.full_name as full_name
        with synonyms ('player', 'player name')
        comment = 'Player full name.',
    players.position_name as position_name
        comment = 'Normalized player position.',
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
    away_teams.away_team_name as team_full_name comment = 'Away team full name.'
)

metrics (
    closing_props.offer_count as count(closing_props.game_player_vendor_prop_key)
        comment = 'Number of player prop offers at closing grain.',
    closing_props.avg_line as avg(closing_props.line_value)
        comment = 'Average offered closing line; use only within one prop type.',
    closing_props.avg_line_movement as avg(closing_props.line_movement)
        comment = 'Average closing-minus-opening movement; use only within one prop type.'
)

comment = 'NFL player prop offers by game, player, sportsbook vendor and prop type. Supports opening and strictly pre-kickoff closing lines, American odds and same-vendor movement. It deliberately does not grade actual prop outcomes because the provider prop taxonomy has not been safely mapped to box-score measures.'

ai_sql_generation 'VENDOR AND PROP TYPE ARE PART OF THE GRAIN: always show or filter both. Never average unlike prop types.
LINE TIMING IS EXPLICIT: opening_props are opening offers; closing_props are the latest observations strictly before kickoff. There are no live or post-kickoff odds.
MOVEMENT: line_movement is closing minus opening for the same game, player, vendor and prop type.
NO OUTCOME CLAIMS: this view does not map prop types to box-score results. Do not say a player went over, under, won or lost a prop.
DEFAULT PHASE: default to Regular Season unless the user requests another phase.
NAME COLLISIONS: if a player name is ambiguous, use position and ask the user to disambiguate.'

ai_question_categorization 'Answer questions about NFL individual-player sportsbook lines, offered prop types, vendors, opening versus closing values, and pregame line movement.
If the question asks about team spreads, team moneylines, game totals or ATS results, route it to NFLGameOddsAnalytics.
If the question asks whether a player actually went over or under, say outcome grading is not available; offer the listed line and movement instead.
If the question asks for live or in-game props, say they are unavailable.'

ai_verified_queries (
    player_prop_movement as (
        question 'How did Patrick Mahomes player prop lines move from opening to closing by sportsbook?'
        verified_at 1786233600
        onboarding_question true
        sql 'SELECT full_name, vendor, prop_type, game_date,
                    opening_line_value, line_value, line_movement
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS players.full_name, closing_props.vendor,
                          closing_props.prop_type, games.game_date
               FACTS closing_props.opening_line_value,
                     closing_props.line_value, closing_props.line_movement)
             WHERE full_name = ''Patrick Mahomes''
             ORDER BY game_date DESC, prop_type, vendor'
    )
)
