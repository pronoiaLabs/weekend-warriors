{{ config(materialized='semantic_view') }}

/*
    sv_wnba_schedule -- the full WNBA slate, one row per game, played or not.

    Grain: game (333 rows), 2026 season. 240 completed, 93 scheduled through
    2026-09-25. This is the ONLY view anchored on dim_wnba_game, and it exists
    because every other WNBA view is anchored on a fact that filters to
    completed games: a scheduled game has no fact row, so "who do the Aces
    play next" is structurally unanswerable anywhere else.

    SCORES ARE DELIBERATELY EXCLUDED, even though dim_wnba_game carries them.
    Results belong to sv_wnba_team_performance; exposing them here would give
    the agent two paths to the same concept, and the one postponed game
    (24935, STATUS 'post' with a fake 0-0 line) would read as a real scoreless
    draw. This view answers "what is on the schedule and what has been
    played", never "who won".

    TIP-OFF TIMES ARE US EASTERN, not UTC. The conversion happens upstream in
    stg_wnba__games (game_datetime_et), so every consumer shares one display
    convention rather than each one shifting at read time. This view exposes
    ONLY the ET column, deliberately: two time columns is an invitation to
    answer with the wrong one. The dimension keeps the name game_datetime so
    the verified queries and the NEXT GAME rule read naturally.

    ROLE-PLAYING JOINS: dim_wnba_team appears twice, as home_teams and
    away_teams, because a schedule row has two participants and "a team's
    schedule" means the OR of both sides. The AI_SQL_GENERATION clause spells
    that out, since it is the single most likely generation mistake here.

    No FACTS clause: a dimension-anchored semantic view is valid DDL (FACTS
    is optional; at least one DIMENSIONS or METRICS clause is required).
*/

tables (
    games as {{ ref('dim_wnba_game') }}
        primary key (game_key)
        with synonyms ('schedule', 'slate', 'fixtures', 'games')
        comment = 'One row per game on the 2026 WNBA calendar, played or not. 333 rows: 240 completed and 93 scheduled through 2026-09-25. Scores are deliberately not exposed here; results live in the team performance view.',

    home_teams as {{ ref('dim_wnba_team') }}
        primary key (team_key)
        with synonyms ('home side', 'host')
        comment = 'The home team in a given game. Same table as away_teams; a team''s full schedule needs both sides.',

    away_teams as {{ ref('dim_wnba_team') }}
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
        comment = 'Calendar date of the game. Completed games run 2026-05-08 to 2026-08-08; scheduled games run through 2026-09-25.',
    games.game_datetime as game_datetime_et
        with synonyms ('tip-off time', 'start time')
        comment = 'Full timestamp including tip-off time, in US EASTERN time (the league''s publishing convention). Same instant as the warehouse''s UTC column, shifted for display; the offset in the value shows -0400 or -0500.',
    games.season as season
        comment = 'WNBA season. This view holds 2026 only.',
    games.season_type_name as season_type_name
        with synonyms ('phase', 'part of season')
        comment = 'Four-way classification: Regular Season, All-Star, Postseason, Preseason. Only Regular Season (332 rows) and All-Star (1 row) exist today; postseason games will appear once the league schedules them.'
        sample_values ('Regular Season', 'All-Star'),

    -- state
    games.game_status as game_status
        comment = 'The source''s own status label: ''pre'' for scheduled, ''post'' for completed. A live in-progress value could appear mid-load.'
        sample_values ('pre', 'post'),
    games.game_state as game_state
        comment = 'Secondary state label from the source. The value ''postponed'' marks game 24935, which is status ''post'' with no result.',
    games.is_completed as is_completed
        with synonyms ('played', 'finished', 'is final')
        comment = 'True for the 240 games already played, false for the 93 still scheduled. This flag, not the date, is the definition of upcoming.',
    games.has_result as has_result
        comment = 'True for the 239 games with a decided result. One game fewer than is_completed: game 24935 on 2026-07-17 is completed-postponed with no result.',
    games.went_to_overtime as went_to_overtime
        comment = 'True for the 10 completed games that needed extra time. Always false on scheduled rows.',

    -- who
    home_teams.home_team_name as team_full_name
        with synonyms ('home team', 'host team')
        comment = 'Full name of the home team.'
        sample_values ('Las Vegas Aces', 'New York Liberty', 'Minnesota Lynx'),
    home_teams.home_team_abbreviation as team_abbreviation
        with synonyms ('home team code')
        comment = 'Short code of the home team.'
        sample_values ('LV', 'NY', 'MIN', 'PHX', 'SEA'),
    home_teams.home_is_franchise as is_franchise
        comment = 'True when the home side is a real franchise. False for All-Star squads and placeholders; filter on it for league questions.',
    away_teams.away_team_name as team_full_name
        with synonyms ('away team', 'visiting team', 'opponent on the road')
        comment = 'Full name of the away team.'
        sample_values ('Las Vegas Aces', 'New York Liberty', 'Minnesota Lynx'),
    away_teams.away_team_abbreviation as team_abbreviation
        with synonyms ('away team code')
        comment = 'Short code of the away team.'
        sample_values ('LV', 'NY', 'MIN', 'PHX', 'SEA'),
    away_teams.away_is_franchise as is_franchise
        comment = 'True when the away side is a real franchise.'
)

metrics (
    games.games_count as count(games.game_key)
        with synonyms ('number of games', 'games on the slate')
        comment = 'Number of games. Grain is one row per GAME, not per team-game, so this counts games directly with no doubling.',
    games.completed_games as sum(iff(games.is_completed, 1, 0))
        with synonyms ('games played so far')
        comment = 'Games already played. 240 today.',
    games.remaining_games as sum(iff(games.is_completed, 0, 1))
        with synonyms ('games left', 'games to play', 'upcoming games count')
        comment = 'Games still to be played. 93 today, through 2026-09-25.'
)

comment = 'The 2026 WNBA schedule at game grain, played and unplayed alike: 333 games, 240 completed and 93 upcoming through 2026-09-25. The only view where future games exist. Use it for the upcoming slate, a team''s next game, games remaining, and schedule questions by date or phase. Tip-off times are US Eastern. Deliberately carries NO scores or results; those belong to the team performance view.'

ai_sql_generation 'TIMES ARE US EASTERN: game_datetime is already converted to US Eastern time for display. Do not convert it again, and say "ET" when presenting a time.
UPCOMING MEANS NOT COMPLETED: for any question about upcoming, next, remaining or future games, filter is_completed = false. Do NOT compare game_date to the current date; the schedule is a nightly snapshot and the completion flag is the source of truth.
A TEAM''S SCHEDULE NEEDS BOTH SIDES: a team appears sometimes as the home team and sometimes as the away team, so "games for the Aces" must use an OR across home and away team name or abbreviation. Filtering only one side silently halves the schedule.
NEXT GAME: a team''s next game is its earliest game_datetime among rows where is_completed = false, with the OR across both sides applied.
GRAIN: one row per GAME, not per team-game. Counting rows counts games directly; nothing here appears twice.
NO RESULTS HERE: this view has no scores, no winners and no records. If a question needs a result, it belongs to the team performance view; do not infer results from this data.
POSTPONED GAME: game_state ''postponed'' marks one completed game with no result (2026-07-17). It is not an upcoming game and not a scoreless draw.
SNAPSHOT, NOT LIVE: the schedule loads nightly. A game played earlier today may still read as not completed.'

ai_question_categorization 'Answer questions about the 2026 WNBA schedule: the upcoming slate, games on a given date or in a given week, a team''s next game or remaining games, how many games are left, and past games as calendar entries.
If the question asks for a SCORE, a RESULT, a RECORD, a winner, or any team or player statistic, mark it out of scope and route it to WNBATeamPerformanceAnalytics or the appropriate player tool; this view holds no results at all.
If the question names a season other than 2026, say this view covers the 2026 season only.
If the question asks about VENUE, arena, city, broadcast or TV information, say the schedule source carries none of it.
If the question asks about playoff scheduling, say the source lists no postseason games yet; they will appear once the league schedules them.'

ai_verified_queries (
    upcoming_this_week as (
        question 'What games are coming up this week?'
        verified_at 1786233600
        onboarding_question true
        sql 'SELECT game_date, game_datetime, home_team_name, away_team_name
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS games.game_date, games.game_datetime,
                          home_teams.home_team_name, away_teams.away_team_name,
                          games.is_completed)
             WHERE NOT is_completed
               AND game_date < DATEADD(day, 7, CURRENT_DATE())
             ORDER BY game_datetime'
    ),
    next_game_for_team as (
        question 'When do the Las Vegas Aces play next?'
        verified_at 1786233600
        sql 'SELECT game_date, game_datetime, home_team_name, away_team_name
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS games.game_date, games.game_datetime,
                          home_teams.home_team_name, away_teams.away_team_name,
                          games.is_completed)
             WHERE NOT is_completed
               AND (home_team_name = ''Las Vegas Aces'' OR away_team_name = ''Las Vegas Aces'')
             ORDER BY game_datetime
             LIMIT 1'
    )
)
