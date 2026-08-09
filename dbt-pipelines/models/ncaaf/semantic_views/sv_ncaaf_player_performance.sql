{{ config(materialized='semantic_view') }}

/*
    sv_ncaaf_player_performance -- player box scores and season rollups.

    TWO FACT GRAINS, DELIBERATELY: player_games (one row per player per
    completed game) for game logs and in-season totals, player_seasons (one
    row per player per season, source-published) for season questions,
    because the source's rate columns carry denominators the game grain
    cannot always reproduce. The AI rules route between them.

    COVERAGE CAVEAT inherited from the source: passing, rushing, receiving
    and defense only. NO fumbles, NO kicking or punting, NO return stats
    anywhere; the categorization declines those rather than answering
    wrong. Season rollups exist for 2024-2025.

    team_key on both facts is the STAT-LINE team (season-accurate across
    transfers); players.current_* answers "who does X play for" only.
*/

tables (
    player_games as {{ ref('fact_ncaaf_player_game') }}
        primary key (player_game_key)
        with synonyms ('box scores', 'game logs', 'player games')
        comment = 'One row per player per completed game: passing, rushing, receiving and defensive lines. Completed games only.',

    player_seasons as {{ ref('fact_ncaaf_player_season') }}
        primary key (player_season_key)
        with synonyms ('season stats', 'season totals')
        comment = 'One row per player per season as the source publishes it, including per-game rates. 2024-2025 today; 2026 appears once the API publishes in-season rollups.',

    players as {{ ref('dim_ncaaf_player') }}
        primary key (player_key)
        with synonyms ('roster', 'athletes')
        comment = 'Player identity and position. current_team_college answers "who does X play for" today; the stat lines carry their own season-accurate team.',

    teams as {{ ref('dim_ncaaf_team') }}
        primary key (team_key)
        with synonyms ('school', 'program')
        comment = 'The stat line''s team (the team the production was earned for).'
)

relationships (
    player_games_to_player as player_games (player_key) references players (player_key),
    player_games_to_team as player_games (team_key) references teams (team_key),
    player_seasons_to_player as player_seasons (player_key) references players (player_key),
    player_seasons_to_team as player_seasons (team_key) references teams (team_key)
)

facts (
    player_games.passing_yards as passing_yards
        comment = 'Passing yards in the game.',
    player_games.rushing_yards as rushing_yards
        comment = 'Rushing yards in the game.',
    player_games.receiving_yards as receiving_yards
        comment = 'Receiving yards in the game.',
    player_seasons.season_passing_yards as passing_yards
        comment = 'Season passing yards as published by the source.',
    player_seasons.season_rushing_yards as rushing_yards
        comment = 'Season rushing yards as published.',
    player_seasons.season_receiving_yards as receiving_yards
        comment = 'Season receiving yards as published.'
)

dimensions (
    player_games.season as season
        comment = 'Season the game belongs to (January bowls belong to the prior year).',
    player_games.week as week
        comment = 'Week 1-16; 999 marks the postseason (use is_postseason).',
    player_games.is_postseason as is_postseason
        comment = 'True for bowl and playoff games.',
    player_games.game_date as game_date
        comment = 'Calendar date of the game.',
    player_games.is_home as is_home
        comment = 'True when the player''s team was home.',

    player_seasons.stat_season as season
        comment = 'Season of the rollup, 2024-2025 today.',

    players.full_name as full_name
        with synonyms ('player', 'player name')
        comment = 'Player full name.'
        sample_values ('Cam Ward', 'Ashton Jeanty', 'Travis Hunter'),
    players.position_name as position_name
        with synonyms ('position')
        comment = 'Position as the source spells it (e.g. Quarterback, Wide Receiver).',
    players.current_team_college as current_team_college
        with synonyms ('plays for', 'current school')
        comment = 'The player''s CURRENT school. For stat questions prefer the stat line''s team below: they disagree across transfers.',

    teams.college as college
        with synonyms ('team', 'school')
        comment = 'The stat line''s school: the team the production was earned for.'
        sample_values ('Georgia', 'Ohio State', 'Boise State')
)

metrics (
    player_games.games_played as count(player_games.player_game_key)
        with synonyms ('games', 'appearances')
        comment = 'Player-game rows in the grouping.',
    player_games.total_passing_yards as sum(player_games.passing_yards)
        comment = 'Passing yards summed from game logs. For a season total, the season fact''s published number is authoritative.',
    player_games.total_rushing_yards as sum(player_games.rushing_yards)
        comment = 'Rushing yards summed from game logs.',
    player_games.total_receiving_yards as sum(player_games.receiving_yards)
        comment = 'Receiving yards summed from game logs.',
    player_games.total_passing_touchdowns as sum(player_games.passing_touchdowns)
        comment = 'Passing touchdowns summed from game logs.',
    player_games.total_rushing_touchdowns as sum(player_games.rushing_touchdowns)
        comment = 'Rushing touchdowns summed from game logs.',
    player_games.total_receiving_touchdowns as sum(player_games.receiving_touchdowns)
        comment = 'Receiving touchdowns summed from game logs.',
    player_games.total_sacks as sum(player_games.sacks)
        comment = 'Sacks summed from game logs.',
    player_games.total_tackles_sum as sum(player_games.total_tackles)
        comment = 'Tackles summed from game logs.',

    player_seasons.season_passing_yards_total as sum(player_seasons.passing_yards)
        comment = 'Source-published season passing yards (grouped, usually per player-season).',
    player_seasons.season_rushing_yards_total as sum(player_seasons.rushing_yards)
        comment = 'Source-published season rushing yards.',
    player_seasons.season_receiving_yards_total as sum(player_seasons.receiving_yards)
        comment = 'Source-published season receiving yards.',
    player_seasons.avg_passing_yards_per_game as avg(player_seasons.passing_yards_per_game)
        comment = 'Source-published passing yards per game.',
    player_seasons.avg_rushing_yards_per_game as avg(player_seasons.rushing_yards_per_game)
        comment = 'Source-published rushing yards per game.',
    player_seasons.avg_receiving_yards_per_game as avg(player_seasons.receiving_yards_per_game)
        comment = 'Source-published receiving yards per game.'
)

comment = 'College football player production, 2024 onward, at two grains: per-game box scores (passing, rushing, receiving, defense) and source-published season rollups with per-game rates. Use it for player stat lines, game logs, season leaders and position questions. Coverage stops at the source''s edge: no fumbles, no kicking/punting, no returns. Team results belong to the team performance view; poll ranks to the rankings view.'

ai_sql_generation 'TWO GRAINS, PICK ONE: game-log questions and custom date ranges use the player_games tables; whole-season questions and per-game rates use player_seasons (its numbers are source-published and authoritative for a season). Never join both grains in one query.
SEASON LEADERS: rank on the season fact for completed seasons (2024, 2025). The in-progress season has no rollup until the source publishes one; sum game logs and say so.
PLAYERS BY NAME: match players.full_name. If two players share a name, disambiguate by position or school rather than merging them.
STAT-LINE TEAM VS CURRENT TEAM: college transfers are common. "How many yards did X have for Y" uses the stat line''s college; "who does X play for" uses current_team_college.
NO SPECIAL TEAMS: the source carries no fumbles, kicking, punting or return stats. Decline those rather than substituting zero.
WEEK 999 IS THE POSTSEASON MARKER, never an ordinal week; use is_postseason.
DEFENSIVE STATS EXIST at both grains: tackles, sacks, interceptions, passes defended. QBR and passing rating exist only where the source published them and can be NULL; averages skip NULLs naturally.
LEADERBOARDS NEED NULLS LAST: most players have NULL for stats outside their role (a linebacker has no passing yards), and Snowflake sorts NULLs FIRST on a descending ORDER BY. Every leaders query must say ORDER BY ... DESC NULLS LAST or filter the stat > 0.'

ai_question_categorization 'Answer questions about individual college football players: game logs, stat lines, season totals and rates, leaders by yards or touchdowns, defensive production, and who plays where.
If the question asks about TEAM results, records or team yardage, route it to the team performance tool.
If the question asks about POLL RANKINGS, route it to the rankings tool; about SCHEDULES, the schedule tool.
If the question asks about fumbles, kicking, punting, returns, or special teams, say the source does not carry those statistics for college football.
If the question names a season before 2024, say coverage starts at 2024.'

ai_verified_queries (
    passing_leaders as (
        question 'Who led FBS in passing yards in 2024?'
        verified_at 1786320000
        onboarding_question true
        sql 'SELECT full_name, college, season_passing_yards_total
             FROM SEMANTIC_VIEW({{ this }}
               METRICS player_seasons.season_passing_yards_total
               DIMENSIONS players.full_name, teams.college, player_seasons.stat_season)
             WHERE stat_season = 2024
             ORDER BY season_passing_yards_total DESC NULLS LAST
             LIMIT 10'
    )
)
