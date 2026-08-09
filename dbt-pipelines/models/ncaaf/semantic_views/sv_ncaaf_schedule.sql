{{ config(materialized='semantic_view') }}

/*
    sv_ncaaf_schedule -- the full college football slate, one row per game,
    played or not.

    Grain: game (~4,977 rows): completed 2024-2025 games plus the full 2026
    schedule (1,623 games, none played as of authoring). This is the ONLY
    view anchored on dim_ncaaf_game, and it exists because every other NCAAF
    view is anchored on a fact filtered to completed games: a scheduled game
    has no fact row, so "who does Ohio State play in week 1" is structurally
    unanswerable anywhere else.

    SCORES ARE DELIBERATELY EXCLUDED. dim_ncaaf_game carries them, but
    results belong to sv_ncaaf_team_performance; exposing them here would
    give the agent two paths to the same concept. This view answers "what is
    on the schedule and what has been played", never "who won".

    KICKOFF TIMES ARE US EASTERN (game_datetime_et upstream), matching the
    convention every sport shares. Only the ET column is exposed; the
    dimension keeps the name game_datetime so the NEXT GAME rule and the
    verified queries read naturally.

    POSTSEASON IS WEEK 999 in this sport (no season_type exists): the
    is_postseason flag is the safe filter, and the AI rules tell the model
    never to treat 999 as an ordinal week.

    ROLE-PLAYING JOINS: dim_ncaaf_team appears twice, home and away; a
    team's schedule means the OR of both sides.

    No FACTS clause: a dimension-anchored semantic view is valid DDL.
*/

tables (
    games as {{ ref('dim_ncaaf_game') }}
        primary key (game_key)
        with synonyms ('schedule', 'slate', 'fixtures', 'games', 'matchups')
        comment = 'One row per game on the college football calendar, played or not: completed games for 2024-2025 and the full 2026 schedule. Scores are deliberately not exposed here; results live in the team performance view.',

    home_teams as {{ ref('dim_ncaaf_team') }}
        primary key (team_key)
        with synonyms ('home side', 'host')
        comment = 'The home team in a given game. Same table as away_teams; a team''s full schedule needs both sides.',

    away_teams as {{ ref('dim_ncaaf_team') }}
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
    games.game_datetime as game_datetime_et
        with synonyms ('kickoff time', 'start time')
        comment = 'Full timestamp including kickoff time, in US EASTERN time (the shared display convention). Same instant as the warehouse''s UTC column; the offset in the value shows -0400 or -0500.',
    games.season as season
        comment = 'College football season, 2024 through 2026. A season''s January games (bowls, CFP) belong to the prior year''s season. 2026 is the only season with unplayed games, so schedule questions mean 2026.',
    games.week as week
        with synonyms ('game week', 'week number')
        comment = 'Week within the season, 1-16 for the regular calendar. WEEK 999 IS NOT A WEEK: it marks bowls and the College Football Playoff. Filter is_postseason instead of comparing against 999.',
    games.is_postseason as is_postseason
        with synonyms ('bowl game', 'playoff', 'CFP')
        comment = 'True for bowls and the College Football Playoff (the source marks them week 999). One known upstream mislabel: the Jan 2025 Gator Bowl carries week 1.',

    -- state
    games.game_status as game_status
        comment = 'The source''s own status label: ''pre'' scheduled, ''post'' completed; a live value could appear mid-load. Use is_completed to separate played from upcoming, never this string.',
    games.is_completed as is_completed
        with synonyms ('played', 'finished', 'is final')
        comment = 'True for played games, false for scheduled ones. This flag, not the date and not the status string, is the definition of upcoming.',
    games.went_to_overtime as went_to_overtime
        comment = 'True for completed games that needed overtime. Always false on scheduled rows.',

    -- who
    home_teams.home_college as college
        with synonyms ('home team', 'home school', 'host school')
        comment = 'The home team''s institution, e.g. ''Ohio State''. What a person means by the team.'
        sample_values ('Ohio State', 'Alabama', 'Michigan', 'Georgia'),
    home_teams.home_team_full_name as team_full_name
        with synonyms ('home team full name')
        comment = 'Institution plus mascot, e.g. ''Ohio State Buckeyes''.',
    home_teams.home_is_fbs as is_fbs
        comment = 'True when the home side is an FBS program. The slate includes FCS opponents; league questions usually mean FBS.',
    away_teams.away_college as college
        with synonyms ('away team', 'away school', 'visiting school')
        comment = 'The away team''s institution.'
        sample_values ('Ohio State', 'Alabama', 'Michigan', 'Georgia'),
    away_teams.away_team_full_name as team_full_name
        with synonyms ('away team full name')
        comment = 'Institution plus mascot.',
    away_teams.away_is_fbs as is_fbs
        comment = 'True when the away side is an FBS program.'
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

comment = 'The college football schedule at game grain, played and unplayed alike: completed games for 2024-2025 plus the full 2026 slate. The only view where future games exist. Use it for the upcoming slate, a team''s next game, a week''s matchups and schedule lookups. Kickoff times are US Eastern. Deliberately carries NO scores or results; those belong to the team performance view.'

ai_sql_generation 'TIMES ARE US EASTERN: game_datetime is already converted to US Eastern time for display. Do not convert it again, and say "ET" when presenting a time.
SCHEDULE QUESTIONS DEFAULT TO 2026: it is the only season with unplayed games, so questions about upcoming games or "this season''s schedule" mean season = 2026 unless another season is named.
UPCOMING MEANS NOT COMPLETED: for upcoming, next, remaining or future games, filter is_completed = false. Do NOT compare game_date to the current date and do NOT parse the game_status string; the schedule is a nightly snapshot and the completion flag is the source of truth.
A TEAM''S SCHEDULE NEEDS BOTH SIDES: a team appears sometimes home and sometimes away, so "games for Ohio State" must OR across home_college and away_college. Filtering only one side silently halves the schedule.
NEXT GAME: a team''s next game is its earliest game_datetime among rows where is_completed = false, with the OR across both sides applied.
WEEK 999 IS THE POSTSEASON MARKER, NOT A WEEK: never treat 999 as an ordinal week, never include it in week ranges, and use is_postseason for bowl/playoff filters. Regular weeks run 1-16.
TEAMS ARE IDENTIFIED BY COLLEGE: match on home_college / away_college (''Ohio State''), not the mascot. Users rarely say ''Buckeyes'' alone; if they do, the full-name dimensions contain it.
FBS BY DEFAULT: the slate includes FCS programs as opponents. Questions about "college football" generally mean FBS; when counting a league-wide slate, filter is_fbs on the home side OR both sides per the question.
GRAIN: one row per GAME. Counting rows counts games directly.
NO RESULTS HERE: this view has no scores, no winners and no records. If a question needs a result, it belongs to the team performance view; do not infer results from this data.
SNAPSHOT, NOT LIVE: the schedule loads nightly at 06:00 UTC. A game played earlier today may still read as not completed.'

ai_question_categorization 'Answer questions about the college football schedule: the upcoming slate, a given week''s matchups, a team''s next game or remaining games, how many games are left, bowl/CFP scheduling as calendar entries, and past games as calendar entries.
If the question asks for a SCORE, a RESULT, a RECORD, a winner, a ranking, or any team or player statistic, mark it out of scope and route it to the appropriate performance or rankings tool; this view holds no results at all.
If the question names a season before 2024, say the schedule coverage starts at 2024.
If the question asks about TV, broadcast, tickets or venues, say the schedule source carries none of it.'

ai_verified_queries (
    week_one_slate as (
        question 'What is the week 1 slate this season?'
        verified_at 1786320000
        onboarding_question true
        sql 'SELECT game_date, game_datetime, home_college, away_college
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS games.game_date, games.game_datetime,
                          home_teams.home_college, away_teams.away_college,
                          games.season, games.week, home_teams.home_is_fbs)
             WHERE season = 2026 AND week = 1 AND home_is_fbs
             ORDER BY game_datetime'
    ),
    next_game_for_team as (
        question 'Who does Ohio State play next?'
        verified_at 1786320000
        sql 'SELECT game_date, game_datetime, home_college, away_college
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS games.game_date, games.game_datetime,
                          home_teams.home_college, away_teams.away_college,
                          games.is_completed)
             WHERE NOT is_completed
               AND (home_college = ''Ohio State'' OR away_college = ''Ohio State'')
             ORDER BY game_datetime
             LIMIT 1'
    )
)
