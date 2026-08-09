{{ config(materialized='semantic_view') }}

/*
    sv_nfl_schedule -- the full NFL slate, one row per game, played or not.

    Grain: game (1,323 rows): the 1,002 completed 2023-2025 games, plus the
    2026 season's 321 games of which one (the Hall of Fame game) is played.
    This is the ONLY view anchored on dim_game, and it exists because every
    other NFL view is anchored on a fact filtered to completed games: a
    scheduled game has no fact row, so "who do the Chiefs play in week 1" is
    structurally unanswerable anywhere else.

    SCORES ARE DELIBERATELY EXCLUDED. dim_game carries none by design (they
    are measures and live on fact_team_game), and this view keeps it that
    way: results belong to sv_nfl_team_performance. This view answers "what
    is on the schedule and what has been played", never "who won".

    NO game_state OR has_result, unlike the WNBA sibling. The NFL source has
    no secondary state label, and ties are real results so is_completed and
    has-a-result are the same thing here.

    ROLE-PLAYING JOINS: dim_team appears twice, as home_teams and away_teams,
    because a schedule row has two participants and "a team's schedule" means
    the OR of both sides.

    No FACTS clause: a dimension-anchored semantic view is valid DDL (FACTS
    is optional; at least one DIMENSIONS or METRICS clause is required).
*/

tables (
    games as {{ ref('dim_game') }}
        primary key (game_key)
        with synonyms ('schedule', 'slate', 'fixtures', 'games', 'matchups')
        comment = 'One row per game on the NFL calendar, played or not: completed games for 2023 through 2025, and the full 2026 schedule of which only the Hall of Fame game has been played. Scores are deliberately not exposed here; results live in the team performance view.',

    home_teams as {{ ref('dim_team') }}
        primary key (team_key)
        with synonyms ('home side', 'host')
        comment = 'The home team in a given game. Same table as away_teams; a team''s full schedule needs both sides.',

    away_teams as {{ ref('dim_team') }}
        primary key (team_key)
        with synonyms ('away side', 'visitor', 'road team')
        comment = 'The away team in a given game. Same table as home_teams; a team''s full schedule needs both sides.'
)

relationships (
    games_to_home_team as games (home_team_key) references home_teams (team_key),
    games_to_away_team as games (away_team_key) references away_teams (team_key)
)

dimensions (
    -- when
    games.game_date as game_date
        with synonyms ('date', 'day of game')
        comment = 'Calendar date of the game.',
    games.game_datetime as game_datetime
        with synonyms ('kickoff time', 'start time')
        comment = 'Full timestamp including kickoff time, in UTC.',
    games.season as season
        comment = 'NFL season, 2023 through 2026. A season''s January and February games belong to the prior year''s season. 2026 is the only season with unplayed games, so schedule questions mean 2026.',
    games.week as week
        with synonyms ('game week', 'week number')
        comment = 'Week within the season phase: 1-18 in the regular season. Week 1 exists in both preseason and regular season, so pair a week filter with the season phase.',
    games.season_type_name as season_type_name
        with synonyms ('phase', 'part of season', 'preseason or regular season')
        comment = 'Preseason, Regular Season, or Postseason. Schedule questions almost always mean Regular Season.'
        sample_values ('Preseason', 'Regular Season', 'Postseason') is_enum,
    games.is_postseason as is_postseason
        comment = 'True for playoff games.',

    -- where
    games.venue as venue
        with synonyms ('stadium', 'where is the game')
        comment = 'Stadium name as the source spells it. NULL on some rows.',

    -- state
    games.game_status as game_status
        comment = 'The source''s own status label: ''Final'' or ''Final/OT'' for completed games; a kickoff-time string like ''9/13 - 1:00 PM EDT'' or ''TBD'' for scheduled ones. Use is_completed to separate played from upcoming, never this string.',
    games.is_completed as is_completed
        with synonyms ('played', 'finished', 'is final')
        comment = 'True for played games, false for scheduled ones. This flag, not the date and not the status string, is the definition of upcoming.',
    games.went_to_overtime as went_to_overtime
        comment = 'True for completed games that needed overtime. Always false on scheduled rows.',

    -- who
    home_teams.home_team_name as team_full_name
        with synonyms ('home team', 'host team')
        comment = 'Full name of the home team.'
        sample_values ('Kansas City Chiefs', 'Detroit Lions', 'Philadelphia Eagles'),
    home_teams.home_team_abbreviation as team_abbreviation
        with synonyms ('home team code')
        comment = 'Short code of the home team.'
        sample_values ('KC', 'DET', 'PHI', 'BUF', 'SF'),
    away_teams.away_team_name as team_full_name
        with synonyms ('away team', 'visiting team')
        comment = 'Full name of the away team.'
        sample_values ('Kansas City Chiefs', 'Detroit Lions', 'Philadelphia Eagles'),
    away_teams.away_team_abbreviation as team_abbreviation
        with synonyms ('away team code')
        comment = 'Short code of the away team.'
        sample_values ('KC', 'DET', 'PHI', 'BUF', 'SF')
)

metrics (
    games.games_count as count(games.game_key)
        with synonyms ('number of games', 'games on the slate')
        comment = 'Number of games. Grain is one row per GAME, not per team-game, so this counts games directly with no doubling.',
    games.completed_games as sum(iff(games.is_completed, 1, 0))
        with synonyms ('games played so far')
        comment = 'Games already played.',
    games.remaining_games as sum(iff(games.is_completed, 0, 1))
        with synonyms ('games left', 'games to play', 'upcoming games count')
        comment = 'Games still to be played. All of them are 2026 games.'
)

comment = 'The NFL schedule at game grain, played and unplayed alike: completed games for the 2023-2025 seasons plus the full 2026 slate (321 games, one played). The only view where future games exist. Use it for the upcoming slate, a team''s next game, the week 1 matchups, bye-week style gap questions and schedule lookups by date, week or venue. Deliberately carries NO scores or results; those belong to the team performance view.'

ai_sql_generation 'SCHEDULE QUESTIONS DEFAULT TO 2026: it is the only season with unplayed games, so questions about upcoming games, the slate, or "this season''s schedule" mean season = 2026 unless another season is named.
UPCOMING MEANS NOT COMPLETED: for any question about upcoming, next, remaining or future games, filter is_completed = false. Do NOT compare game_date to the current date and do NOT parse the game_status string; the schedule is a nightly snapshot and the completion flag is the source of truth.
A TEAM''S SCHEDULE NEEDS BOTH SIDES: a team appears sometimes as the home team and sometimes as the away team, so "games for the Chiefs" must use an OR across home and away team name or abbreviation. Filtering only one side silently halves the schedule.
NEXT GAME: a team''s next game is its earliest game_datetime among rows where is_completed = false, with the OR across both sides applied.
WEEKS NEED A PHASE: week numbers restart per season phase, so "week 1" must also filter season_type_name = ''Regular Season'' unless the user says preseason or playoffs.
GRAIN: one row per GAME, not per team-game. Counting rows counts games directly; nothing here appears twice.
NO RESULTS HERE: this view has no scores, no winners and no records. If a question needs a result, it belongs to the team performance view; do not infer results from this data.
TBD GAMES: 24 late-season 2026 games carry game_status ''TBD'' with placeholder kickoff times, because the league flexes them later. Say the time is not yet set rather than quoting the placeholder.
SNAPSHOT, NOT LIVE: the schedule loads nightly. A game played earlier today may still read as not completed.'

ai_question_categorization 'Answer questions about the NFL schedule: the upcoming slate, a given week''s matchups, a team''s next game or remaining games, how many games are left, venues, and past games as calendar entries.
If the question asks for a SCORE, a RESULT, a RECORD, a winner, or any team or player statistic, mark it out of scope and route it to NFLTeamPerformanceAnalytics or the appropriate player tool; this view holds no results at all.
If the question names a season before 2023, say the schedule coverage starts at 2023.
If the question asks about BROADCAST, TV channel or ticket information, say the schedule source carries none of it.
If the question asks which playoff games are scheduled, say the 2026 postseason is not yet on the schedule; playoff rows exist only for completed past seasons.'

ai_verified_queries (
    week_one_slate as (
        question 'What is the week 1 slate this season?'
        verified_at 1786233600
        onboarding_question true
        sql 'SELECT game_date, game_datetime, home_team_name, away_team_name
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS games.game_date, games.game_datetime,
                          home_teams.home_team_name, away_teams.away_team_name,
                          games.season, games.week, games.season_type_name)
             WHERE season = 2026 AND week = 1
               AND season_type_name = ''Regular Season''
             ORDER BY game_datetime'
    ),
    next_game_for_team as (
        question 'Who do the Kansas City Chiefs play next?'
        verified_at 1786233600
        sql 'SELECT game_date, game_datetime, home_team_name, away_team_name
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS games.game_date, games.game_datetime,
                          home_teams.home_team_name, away_teams.away_team_name,
                          games.is_completed)
             WHERE NOT is_completed
               AND (home_team_name = ''Kansas City Chiefs'' OR away_team_name = ''Kansas City Chiefs'')
             ORDER BY game_datetime
             LIMIT 1'
    )
)
