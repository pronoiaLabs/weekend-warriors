{{ config(materialized='semantic_view') }}

/*
    sv_nfl_schedule -- the full NFL slate, one row per game, played or not.

    Grain: game (1,323 rows): 1,024 completed (2023-2025 plus 22 of 2026
    preseason) and 299 upcoming (27 preseason + 272 regular). This is the
    ONLY view anchored on dim_game, and it exists because every other NFL
    view is anchored on a fact filtered to completed games: a scheduled
    game has no fact row, so "who do the Chiefs play in week 1" is
    structurally unanswerable anywhere else.

    SCORES ARE DELIBERATELY EXCLUDED. dim_game carries none by design (they
    are measures and live on fact_team_game_offense), and this view keeps it that
    way: results belong to sv_nfl_team_performance. game_summary is also
    excluded — live recaps include scores. This view answers "what is on
    the schedule and what has been played", never "who won".

    Weather facts here are FORECAST only (fact_game_weather_forecast). ERA5
    actuals live on fact_game_weather and stay off this view so a pregame
    question cannot peek at what happened.

    KICKOFF TIMES ARE US EASTERN, not UTC. The conversion happens upstream
    in stg_nfl__games (game_datetime_et). This view exposes ONLY the ET
    column.

    ROLE-PLAYING JOINS: dim_team appears twice, as home_teams and away_teams.
*/

tables (
    games as {{ ref('dim_game') }}
        primary key (game_key)
        with synonyms ('schedule', 'slate', 'fixtures', 'games', 'matchups')
        comment = 'One row per game on the NFL calendar, played or not: 1,323 games, 299 still upcoming as of Aug 22 2026. Scores are deliberately not exposed here; results live in the team performance view.',

    stadiums as {{ ref('dim_stadium') }}
        primary key (stadium_key)
        with synonyms ('stadium', 'bowl', 'venue details')
        comment = 'Physical bowl for the game. Collapses feed renames. Roof and is_weather_relevant gate whether outdoor conditions matter.',

    weather as {{ ref('fact_game_weather_forecast') }}
        primary key (game_key)
        with synonyms ('forecast', 'kickoff weather', 'game-day weather')
        comment = 'Live Open-Meteo forecast at the kickoff hour. One row per game when a forecast has landed. Not ERA5 actuals.',

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
    games_to_stadium as games (stadium_key) references stadiums (stadium_key),
    weather_to_game as weather (game_key) references games (game_key),
    games_to_home_team as games (home_team_key) references home_teams (team_key),
    games_to_away_team as games (away_team_key) references away_teams (team_key)
)

facts (
    weather.kickoff_temp_f as kickoff_temp_f
        comment = 'Forecast temperature at kickoff, Fahrenheit. Ignore when is_weather_relevant is false.',
    weather.wind_mph as wind_mph
        comment = 'Forecast sustained wind at kickoff, mph. Ignore when is_weather_relevant is false.',
    weather.gust_mph as gust_mph
        comment = 'Forecast wind gusts at kickoff, mph.',
    weather.wind_dir_deg as wind_dir_deg
        comment = 'Forecast wind direction at kickoff, degrees from north.',
    weather.precip_in as precip_in
        comment = 'Forecast precipitation at the kickoff hour, inches.',
    weather.hours_before_kickoff as hours_before_kickoff
        comment = 'Hours between the forecast load and kickoff. Describes staleness, not a live radar.'
)

dimensions (
    -- when
    games.game_date as game_date
        with synonyms ('date', 'day of game')
        comment = 'Calendar date of the game.',
    games.game_datetime as game_datetime_et
        with synonyms ('kickoff time', 'start time')
        comment = 'Full timestamp including kickoff time, in US EASTERN time (the league''s publishing convention, matching the kickoff-time status strings). Same instant as the warehouse''s UTC column, shifted for display; the offset in the value shows -0400 or -0500.',
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
        with synonyms ('stadium name', 'where is the game')
        comment = 'Stadium name as the source spells it. Every row has one; aliases such as GEHA Field at Arrowhead Stadium and Arrowhead Stadium are the same bowl.',
    stadiums.stadium_display_name as display_name
        with synonyms ('stadium', 'bowl name')
        comment = 'Canonical stadium name after alias collapse.',
    stadiums.roof as roof
        with synonyms ('roof type', 'dome', 'open air')
        comment = 'open, retractable, or fixed. Outdoors questions mean roof is open or retractable.'
        sample_values ('open', 'retractable', 'fixed') is_enum,
    stadiums.is_weather_relevant as is_weather_relevant
        with synonyms ('weather matters', 'outdoor game')
        comment = 'False for fixed roofs (SoFi, Ford Field, Allegiant, Superdome, U.S. Bank). When false, do not cite wind or temperature as affecting the game.',
    stadiums.is_international as is_international
        with synonyms ('overseas', 'neutral site abroad', 'London game')
        comment = 'True for games in London, Europe, Brazil, Mexico, Australia. False for Canton and regular-season homes.',
    stadiums.elevation_m as elevation_m
        with synonyms ('altitude', 'elevation')
        comment = 'Stadium elevation in metres. Mile High is the regular-season home where this is the question.',
    stadiums.surface as surface
        with synonyms ('field surface', 'grass or turf')
        comment = 'grass or turf.',

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
    home_teams.team_location as team_location
        with synonyms ('home city', 'home location')
        comment = 'Home team city or region, e.g. Kansas City, New York.',
    home_teams.conference as conference
        comment = 'AFC or NFC of the home team.'
        sample_values ('AFC', 'NFC') is_enum,
    home_teams.division as division
        comment = 'Division of the home team. Uppercase in the data.'
        sample_values ('EAST', 'NORTH', 'SOUTH', 'WEST') is_enum,
    away_teams.away_team_name as team_full_name
        with synonyms ('away team', 'visiting team')
        comment = 'Full name of the away team.'
        sample_values ('Kansas City Chiefs', 'Detroit Lions', 'Philadelphia Eagles'),
    away_teams.away_team_abbreviation as team_abbreviation
        with synonyms ('away team code')
        comment = 'Short code of the away team.'
        sample_values ('KC', 'DET', 'PHI', 'BUF', 'SF'),
    away_teams.team_location as team_location
        with synonyms ('away city', 'away location')
        comment = 'Away team city or region.',
    away_teams.conference as conference
        comment = 'AFC or NFC of the away team.'
        sample_values ('AFC', 'NFC') is_enum,
    away_teams.division as division
        comment = 'Division of the away team.'
        sample_values ('EAST', 'NORTH', 'SOUTH', 'WEST') is_enum
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

comment = 'The NFL schedule at game grain, played and unplayed alike: 1,323 games with 299 still upcoming (Aug 22 2026). The only view where future games exist. Includes stadium roof / weather-relevance and a kickoff-hour forecast when one has landed. Kickoff times are US Eastern. Deliberately carries NO scores, results, or ERA5 actuals; those belong elsewhere.'

ai_sql_generation 'TIMES ARE US EASTERN: game_datetime is already converted to US Eastern time for display, matching the kickoff-time status strings. Do not convert it again, and say "ET" when presenting a time.
SCHEDULE QUESTIONS DEFAULT TO 2026: it is the only season with unplayed games, so questions about upcoming games, the slate, or "this season''s schedule" mean season = 2026 unless another season is named.
UPCOMING MEANS NOT COMPLETED: for any question about upcoming, next, remaining or future games, filter is_completed = false. Do NOT compare game_date to the current date and do NOT parse the game_status string; the schedule is a nightly snapshot and the completion flag is the source of truth.
A TEAM''S SCHEDULE NEEDS BOTH SIDES: a team appears sometimes as the home team and sometimes as the away team, so "games for the Chiefs" must use an OR across home and away team name or abbreviation. Filtering only one side silently halves the schedule.
NEXT GAME: a team''s next game is its earliest game_datetime among rows where is_completed = false, with the OR across both sides applied.
WEEKS NEED A PHASE: week numbers restart per season phase, so "week 1" must also filter season_type_name = ''Regular Season'' unless the user says preseason or playoffs.
GRAIN: one row per GAME, not per team-game. Counting rows counts games directly; nothing here appears twice.
NO RESULTS HERE: this view has no scores, no winners and no records. If a question needs a result, it belongs to the team performance view; do not infer results from this data. Do not read game recaps; they are not on this view.
OUTDOORS: roof in (''open'', ''retractable'') or is_weather_relevant = true. Fixed-roof games are indoor; do not cite wind or temperature as affecting those games even if a forecast row exists.
FORECAST IS A DAILY SNAPSHOT: hours_before_kickoff says how stale the outlook is. Do not describe it as live radar. TBD kickoffs may have no weather row yet.
TBD GAMES: 24 late-season 2026 games carry game_status ''TBD'' with placeholder kickoff times, because the league flexes them later. Say the time is not yet set rather than quoting the placeholder.
SNAPSHOT, NOT LIVE: the schedule loads nightly. A game played earlier today may still read as not completed.'

ai_question_categorization 'Answer questions about the NFL schedule: the upcoming slate, a given week''s matchups, a team''s next game or remaining games, how many games are left, venues, roof type, outdoor vs indoor, international sites, and kickoff-hour forecast conditions.
If the question asks for a SCORE, a RESULT, a RECORD, a winner, or any team or player statistic, mark it out of scope and route it to NFLTeamPerformanceAnalytics or the appropriate player tool; this view holds no results at all.
If the question asks what the weather actually was after a game (ERA5 / observed), say this view holds the pregame forecast only.
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
    ),
    week_one_outdoors as (
        question 'Which week 1 games are outdoors this season?'
        verified_at 1787390000
        sql 'SELECT game_date, game_datetime, home_team_name, away_team_name, venue, roof
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS games.game_date, games.game_datetime,
                          home_teams.home_team_name, away_teams.away_team_name,
                          games.venue, stadiums.roof,
                          games.season, games.week, games.season_type_name)
             WHERE season = 2026 AND week = 1
               AND season_type_name = ''Regular Season''
               AND roof IN (''open'', ''retractable'')
             ORDER BY game_datetime'
    )
)
