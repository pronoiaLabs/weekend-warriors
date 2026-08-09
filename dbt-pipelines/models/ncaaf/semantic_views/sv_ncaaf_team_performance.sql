{{ config(materialized='semantic_view') }}

/*
    sv_ncaaf_team_performance -- results and team production, completed
    games only.

    Anchor: fact_ncaaf_team_game (one row per team per completed game, two
    per game), with role-playing team/opponent joins and game context.
    Scheduled games do not exist here AT ALL; the slate belongs to
    sv_ncaaf_schedule, and the AI rules route "next game" questions away.

    THE GRAIN DOUBLES LEAGUE-WIDE COUNTS: every game contributes two rows,
    one per side. Team-scoped questions ("Georgia's wins") are correct
    as-is; league-wide game counts must halve or count distinct games. The
    rules say so.

    The yardage block is nullable (a handful of completed games lack a box
    score upstream; has_box_score marks them), so yardage averages use the
    non-null rows only, which AVG() does naturally.
*/

tables (
    team_games as {{ ref('fact_ncaaf_team_game') }}
        primary key (team_game_key)
        with synonyms ('results', 'games played', 'box scores')
        comment = 'One row per team per COMPLETED game (two rows per game, one per side): result, points, and the team box score where the source provided one. No scheduled games exist here.',

    teams as {{ ref('dim_ncaaf_team') }}
        primary key (team_key)
        with synonyms ('school', 'program')
        comment = 'The team the row belongs to. Identified by college (institution name). Filter is_fbs for league-wide questions.',

    opponents as {{ ref('dim_ncaaf_team') }}
        primary key (team_key)
        with synonyms ('opposing team', 'against')
        comment = 'The opponent in the same game. Same table as teams, joined through the opponent key.',

    games as {{ ref('dim_ncaaf_game') }}
        primary key (game_key)
        comment = 'Game context: date, season, week, postseason flag, overtime.'
)

relationships (
    team_games_to_team as team_games (team_key) references teams (team_key),
    team_games_to_opponent as team_games (opponent_team_key) references opponents (team_key),
    team_games_to_game as team_games (game_key) references games (game_key)
)

facts (
    team_games.points_scored as points_scored
        comment = 'Points this team scored in the game.',
    team_games.points_allowed as points_allowed
        comment = 'Points the opponent scored.',
    team_games.point_differential as point_differential
        comment = 'points_scored minus points_allowed; negative in a loss.',
    team_games.total_yards as total_yards
        comment = 'Total offensive yards. NULL when the box score is missing upstream (see has_box_score).',
    team_games.passing_yards as passing_yards
        comment = 'Team passing yards in the game.',
    team_games.rushing_yards as rushing_yards
        comment = 'Team rushing yards in the game.',
    team_games.turnovers as turnovers
        comment = 'Turnovers committed by this team.'
)

dimensions (
    team_games.season as season
        comment = 'Season, 2024-2025 today; 2026 rows appear as games complete. January bowl games belong to the prior year''s season.',
    team_games.week as week
        comment = 'Week 1-16 in the regular calendar. WEEK 999 IS THE POSTSEASON MARKER, not a week; filter is_postseason instead.',
    team_games.is_postseason as is_postseason
        with synonyms ('bowl game', 'playoff', 'CFP')
        comment = 'True for bowls and the College Football Playoff.',
    team_games.game_date as game_date
        comment = 'Calendar date of the game.',
    team_games.is_home as is_home
        with synonyms ('at home', 'home game')
        comment = 'True when this row''s team was the home side.',
    team_games.result as result
        with synonyms ('won or lost', 'outcome')
        comment = 'W, L or T from this team''s perspective. Ties are historical rarities kept for correctness.'
        sample_values ('W', 'L', 'T') is_enum,
    team_games.went_to_overtime as went_to_overtime
        comment = 'True when the game needed overtime.',
    team_games.has_box_score as has_box_score
        comment = 'False for the handful of completed games whose yardage block is missing upstream; their scores and results are still real.',

    teams.college as college
        with synonyms ('team', 'school name')
        comment = 'The team''s institution, e.g. ''Georgia''.'
        sample_values ('Georgia', 'Ohio State', 'Alabama', 'Oregon'),
    teams.team_full_name as team_full_name
        comment = 'Institution plus mascot.',
    teams.conference_name as conference_name
        with synonyms ('conference')
        comment = 'The team''s CURRENT conference; realignment history is not tracked here.',
    teams.is_fbs as is_fbs
        comment = 'True for FBS programs (~134 of 536 teams). League-wide questions almost always mean FBS.',

    opponents.opponent_college as college
        with synonyms ('opponent', 'against team')
        comment = 'The opponent''s institution.'
        sample_values ('Georgia', 'Ohio State', 'Alabama', 'Oregon'),
    opponents.opponent_is_fbs as is_fbs
        comment = 'True when the opponent is an FBS program. False marks FCS "buy games".'
)

metrics (
    team_games.games_played as count(team_games.team_game_key)
        with synonyms ('number of games')
        comment = 'Rows counted. Correct for a single team''s games; LEAGUE-WIDE this counts team-games (two per game), so halve it or count distinct games for "how many games were played".',
    team_games.wins as sum(iff(team_games.result = 'W', 1, 0))
        with synonyms ('number of wins')
        comment = 'Games won.',
    team_games.losses as sum(iff(team_games.result = 'L', 1, 0))
        with synonyms ('number of losses')
        comment = 'Games lost.',
    team_games.win_pct as avg(iff(team_games.result = 'W', 1.0, 0.0))
        with synonyms ('winning percentage', 'win rate')
        comment = 'Share of games won across the grouped rows. Ties count as losses here; the standings view carries the official percentage.',
    team_games.points_per_game as avg(team_games.points_scored)
        with synonyms ('scoring average', 'offense points')
        comment = 'Average points scored.',
    team_games.points_allowed_per_game as avg(team_games.points_allowed)
        with synonyms ('defense points', 'points given up per game')
        comment = 'Average points allowed.',
    team_games.yards_per_game as avg(team_games.total_yards)
        comment = 'Average total yards, over games that have a box score.',
    team_games.turnovers_per_game as avg(team_games.turnovers)
        comment = 'Average turnovers committed, over games that have a box score.'
)

comment = 'Team results and production for completed college football games, 2024 onward: wins, losses, points, yardage and turnovers at team-game grain (two rows per game, one per side), with team, opponent and game context. Use it for records, results, head-to-head history, scoring and yardage questions. No scheduled games and no poll ranks: the schedule and rankings views own those.'

ai_sql_generation 'COMPLETED GAMES ONLY: scheduled games do not exist in this view. Questions about upcoming games or "who do they play next" belong to the schedule view; never answer them from here.
TEAMS ARE IDENTIFIED BY COLLEGE (''Georgia''), not the mascot.
GRAIN IS TEAM-GAME: every game appears twice, once per side. A single team''s stats are correct as filtered; league-wide game counts must count DISTINCT games or halve the row count.
FBS BY DEFAULT: league-wide leaderboards and averages should filter is_fbs = true unless the user asks about FCS. Beware FCS opponents inflating records: opponent_is_fbs = false marks buy games.
WEEK 999 IS THE POSTSEASON MARKER, never an ordinal week; use is_postseason.
HEAD TO HEAD: "Georgia vs Alabama" filters college = ''Georgia'' AND opponent_college = ''Alabama''; that returns Georgia''s perspective and each game exactly once.
YARDAGE IS NULLABLE: a few completed games lack a box score (has_box_score = false); their results still count, and yardage averages already skip them via NULL.
OFFICIAL RECORDS: won-lost records computed here reflect loaded games; the standings view carries the source''s official record and win percentage when exactness matters.
SEASONS: 2024 and 2025 are complete; 2026 accrues from late August 2026.'

ai_question_categorization 'Answer questions about completed college football games and team production: records, results, scores, head-to-head history, points for and against, yardage, turnovers, home/away splits, and postseason results.
If the question asks about UPCOMING games, the schedule, or kickoff times, mark it out of scope and route it to the schedule tool.
If the question asks about POLL RANKINGS, route it to the rankings tool.
If the question asks about an individual PLAYER, route it to the player performance tool.
If the question asks for official standings positions or conference standings, note the standings-derived record here is computed from loaded games and offer the team''s W-L; exact official standings live with the source.'

ai_verified_queries (
    team_record as (
        question 'What was Georgia''s record in 2024?'
        verified_at 1786320000
        onboarding_question true
        sql 'SELECT wins, losses
             FROM SEMANTIC_VIEW({{ this }}
               METRICS team_games.wins, team_games.losses
               DIMENSIONS teams.college, team_games.season)
             WHERE college = ''Georgia'' AND season = 2024'
    ),
    top_scoring_teams as (
        question 'Which FBS teams scored the most points per game in 2024?'
        verified_at 1786320000
        sql 'SELECT college, points_per_game
             FROM SEMANTIC_VIEW({{ this }}
               METRICS team_games.points_per_game
               DIMENSIONS teams.college, teams.is_fbs, team_games.season)
             WHERE season = 2024 AND is_fbs
             ORDER BY points_per_game DESC
             LIMIT 10'
    )
)
