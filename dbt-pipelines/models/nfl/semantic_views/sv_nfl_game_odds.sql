{{ config(materialized='semantic_view') }}

/*
    NFL sportsbook game markets at game x vendor grain. Opening and closing
    tables are one-to-one on game_vendor_odds_key. Closing is strictly pregame;
    no live or post-kickoff snapshot reaches this semantic view.
*/

tables (
    opening_odds as {{ ref('fact_game_betting_odds_opening') }}
        primary key (game_vendor_odds_key)
        with synonyms ('opening lines', 'openers')
        comment = 'One row per game and sportsbook vendor at market open.',

    closing_odds as {{ ref('fact_game_betting_odds_closing') }}
        primary key (game_vendor_odds_key)
        with synonyms ('closing lines', 'pregame odds')
        comment = 'One row per game and sportsbook vendor: latest snapshot observed strictly before kickoff. Includes same-vendor opening values and movement.',

    games as {{ ref('dim_game') }}
        primary key (game_key)
        comment = 'Game date, season, week and completion context.',

    home_teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'Home team role.',

    away_teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'Away team role.'
)

relationships (
    closing_to_opening as closing_odds (game_vendor_odds_key) references opening_odds (game_vendor_odds_key),
    closing_to_game as closing_odds (game_key) references games (game_key),
    closing_to_home_team as closing_odds (home_team_key) references home_teams (team_key),
    closing_to_away_team as closing_odds (away_team_key) references away_teams (team_key),
    opening_to_game as opening_odds (game_key) references games (game_key),
    opening_to_home_team as opening_odds (home_team_key) references home_teams (team_key),
    opening_to_away_team as opening_odds (away_team_key) references away_teams (team_key)
)

facts (
    opening_odds.home_spread as home_spread comment = 'Opening home-team spread.',
    opening_odds.away_spread as away_spread comment = 'Opening away-team spread.',
    opening_odds.home_moneyline_odds as home_moneyline_odds comment = 'Opening home American moneyline odds.',
    opening_odds.away_moneyline_odds as away_moneyline_odds comment = 'Opening away American moneyline odds.',
    opening_odds.total_line as total_line comment = 'Opening over/under total.',
    closing_odds.home_spread as home_spread comment = 'Closing home-team spread.',
    closing_odds.away_spread as away_spread comment = 'Closing away-team spread.',
    closing_odds.home_moneyline_odds as home_moneyline_odds comment = 'Closing home American moneyline odds.',
    closing_odds.away_moneyline_odds as away_moneyline_odds comment = 'Closing away American moneyline odds.',
    closing_odds.total_line as total_line comment = 'Closing over/under total.',
    closing_odds.home_moneyline_implied_probability as home_moneyline_implied_probability
        comment = 'Raw closing probability implied by home American odds, including vig.',
    closing_odds.away_moneyline_implied_probability as away_moneyline_implied_probability
        comment = 'Raw closing probability implied by away American odds, including vig.',
    closing_odds.home_moneyline_devig_probability as home_moneyline_devig_probability
        comment = 'Closing home win probability normalized across both sides to remove vig.',
    closing_odds.away_moneyline_devig_probability as away_moneyline_devig_probability
        comment = 'Closing away win probability normalized across both sides to remove vig.',
    closing_odds.home_spread_implied_probability as home_spread_implied_probability
        comment = 'Raw probability implied by the closing home spread price.',
    closing_odds.away_spread_implied_probability as away_spread_implied_probability
        comment = 'Raw probability implied by the closing away spread price.',
    closing_odds.over_implied_probability as over_implied_probability
        comment = 'Raw probability implied by the closing over price.',
    closing_odds.under_implied_probability as under_implied_probability
        comment = 'Raw probability implied by the closing under price.',
    closing_odds.implied_home_team_total as implied_home_team_total
        comment = 'Closing implied home points from total / 2 minus home spread / 2.',
    closing_odds.implied_away_team_total as implied_away_team_total
        comment = 'Closing implied away points from total / 2 plus home spread / 2.',
    closing_odds.opening_home_spread as opening_home_spread
        comment = 'Same-vendor opening home spread carried onto the closing row.',
    closing_odds.opening_total_line as opening_total_line
        comment = 'Same-vendor opening total carried onto the closing row.',
    closing_odds.home_spread_movement as home_spread_movement
        comment = 'Closing minus opening home spread for the same vendor.',
    closing_odds.total_line_movement as total_line_movement
        comment = 'Closing minus opening total for the same vendor.',
    closing_odds.home_team_score as home_team_score comment = 'Final home score; NULL before completion.',
    closing_odds.away_team_score as away_team_score comment = 'Final away score; NULL before completion.',
    closing_odds.actual_total as actual_total comment = 'Final combined score; NULL before completion.'
)

dimensions (
    closing_odds.vendor as vendor
        comment = 'Sportsbook vendor. Never combine vendors unless the question asks for a market consensus.',
    closing_odds.line_timing as line_timing
        comment = 'Always closing for closing_odds; selected strictly before kickoff.'
        sample_values ('closing') is_enum,
    opening_odds.line_timing as line_timing
        comment = 'Always opening for opening_odds.'
        sample_values ('opening') is_enum,
    closing_odds.selected_snapshot_at as selected_snapshot_at
        comment = 'Timestamp of the selected pre-kickoff closing observation.',
    games.game_date as game_date comment = 'Game calendar date.',
    games.season as season comment = 'NFL season year.',
    games.week as week comment = 'Week within the season phase.',
    games.season_type_name as season_type_name
        comment = 'Preseason, Regular Season, or Postseason.'
        sample_values ('Preseason', 'Regular Season', 'Postseason') is_enum,
    home_teams.home_team_name as team_full_name
        comment = 'Home team full name.',
    away_teams.away_team_name as team_full_name
        comment = 'Away team full name.',
    closing_odds.home_spread_result as home_spread_result
        comment = 'Completed-game home ATS result at the closing line: cover, no cover, or push. NULL before completion.'
        sample_values ('cover', 'no cover', 'push') is_enum,
    closing_odds.total_result as total_result
        comment = 'Completed-game result against the closing total: over, under, or push. NULL before completion.'
        sample_values ('over', 'under', 'push') is_enum
)

metrics (
    closing_odds.market_count as count(closing_odds.game_vendor_odds_key)
        comment = 'Number of game-vendor closing markets.',
    closing_odds.home_covers as sum(iff(closing_odds.home_spread_result = 'cover', 1, 0))
        comment = 'Completed games where the home team covered this vendor closing spread.',
    closing_odds.overs as sum(iff(closing_odds.total_result = 'over', 1, 0))
        comment = 'Completed games that finished over this vendor closing total.',
    closing_odds.avg_home_devig_probability as avg(closing_odds.home_moneyline_devig_probability)
        comment = 'Average de-vigged closing home win probability.'
)

comment = 'NFL game betting markets by sportsbook vendor, with explicit opening and strictly pre-kickoff closing lines. Supports moneyline, spread, total, implied probabilities, implied team totals, opening-to-closing movement, and completed-game ATS/over-under results. It contains no live or post-kickoff odds.'

ai_sql_generation 'VENDOR IS PART OF THE GRAIN: every game can have several sportsbook rows. Always show or filter vendor. Do not average vendors unless the user explicitly asks for consensus.
LINE TIMING IS EXPLICIT: opening_odds are opening; closing_odds are the latest observation strictly before kickoff. Never describe closing as live or final after the game.
AMERICAN ODDS: positive and negative odds are American format. Use the provided implied and de-vigged probability facts rather than rebuilding the conversion.
MOVEMENT DIRECTION: movement is closing minus opening for the same vendor. For a home spread, movement from -3 to -4 is -1.
ATS AND TOTAL RESULTS: home_spread_result and total_result are populated only for completed games. Pushes are separate from wins/losses and overs/unders.
DEFAULT PHASE: default to Regular Season unless the user requests preseason or postseason.
GRAIN: one row per GAME x VENDOR in each line-timing table. Counting across vendors counts markets, not unique games.'

ai_question_categorization 'Answer NFL team and matchup betting questions about sportsbook moneylines, spreads, totals, implied probabilities, implied team totals, opening versus closing movement, ATS covers, and over/under results.
If the question asks about an individual player prop or player line, route it to NFLPlayerPropsAnalytics.
If the question asks for live or in-game odds, say they are unavailable: closing rows are strictly pre-kickoff.
If the question asks for wagering advice, explain the historical market data without presenting it as a guaranteed prediction.'

ai_verified_queries (
    game_line_movement as (
        question 'How did the Chiefs game line move from opening to closing by sportsbook?'
        verified_at 1786233600
        onboarding_question true
        sql 'SELECT vendor, game_date, home_team_name, away_team_name,
                    opening_home_spread, home_spread, home_spread_movement,
                    opening_total_line, total_line, total_line_movement
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS closing_odds.vendor, games.game_date,
                          home_teams.home_team_name, away_teams.away_team_name
               FACTS closing_odds.opening_home_spread, closing_odds.home_spread,
                     closing_odds.home_spread_movement, closing_odds.opening_total_line,
                     closing_odds.total_line, closing_odds.total_line_movement)
             WHERE home_team_name = ''Kansas City Chiefs''
                OR away_team_name = ''Kansas City Chiefs''
             ORDER BY game_date DESC, vendor'
    )
)
