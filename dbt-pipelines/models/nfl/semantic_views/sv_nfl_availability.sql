{{ config(materialized='semantic_view') }}

/*
    sv_nfl_availability -- who is available to play: the official injury
    report, the depth chart in effect at kickoff, and the player's current
    Sleeper status.

    TWO INDEPENDENT FACTS, DELIBERATELY UNRELATED. injury_reports (the filed
    designations, one row per filed report) and depth_charts (one row per
    chart slot) share players, teams and games but have NO relationship to
    each other: they answer different questions at different grains, and a
    join between them would fan out and reconcile nothing.

    THREE CLOCKS. The injury report is HISTORY anchored to a season and week.
    The depth chart is HISTORY anchored to a game. The players table carries
    a current_* block from Sleeper that is AS OF NOW, replaced daily with no
    history. Never blend them into one number.

    game_key is NULL on injury report rows whose team-week never bridged to
    a game (early historical gaps); the report still anchors by season and
    week, so filter on those rather than on the game.
*/

tables (
    injury_reports as {{ ref('fact_injury_report') }}
        primary key (injury_report_key)
        with synonyms ('injury report', 'injury designations', 'practice report')
        comment = 'The league''s official injury report: one row per filed report, season x week x team x player. report_status is the game designation, practice_status the participation line. This is filed history, not current status.',

    depth_charts as {{ ref('fact_depth_chart') }}
        primary key (depth_chart_key)
        with synonyms ('depth chart', 'depth', 'starters')
        comment = 'The depth chart in effect at kickoff, one row per chart slot per team-game. Two source shapes: the league''s weekly file for 2023-24 and daily snapshots from 2025 onward, unified game-anchored.',

    players as {{ ref('dim_player') }}
        primary key (player_key)
        comment = 'Player identity and position, plus a current_* status block from Sleeper that is as-of-now only.',

    teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'The 32 NFL teams with conference and division.',

    games as {{ ref('dim_game') }}
        primary key (game_key)
        comment = 'Game context: date, season, week, phase, completion. NULL game_key on some injury report rows means the report week never bridged to a game.'
)

relationships (
    report_to_player as injury_reports (player_key) references players (player_key),
    report_to_team as injury_reports (team_key) references teams (team_key),
    report_to_game as injury_reports (game_key) references games (game_key),
    chart_to_player as depth_charts (player_key) references players (player_key),
    chart_to_team as depth_charts (team_key) references teams (team_key),
    chart_to_game as depth_charts (game_key) references games (game_key)
)

dimensions (
    -- the filed injury report: history, anchored to season and week
    injury_reports.season as season
        comment = 'NFL season the report was filed in.',
    injury_reports.week as week
        comment = 'Week in nflverse continuous numbering: regular season 1 to 18, postseason continues 19 to 22. The report anchors by season and week even when game_key is NULL on unbridged rows.',
    injury_reports.season_type as season_type
        comment = 'Season phase in nflverse numeric coding, carried from the source. The report anchors by season and week even when game_key is NULL on unbridged rows.',
    injury_reports.report_status as report_status
        with synonyms ('designation', 'game status', 'injury designation')
        comment = 'The filed game designation, e.g. Out, Doubtful, Questionable. NULL when the club listed the player without a game designation.'
        sample_values ('Out', 'Doubtful', 'Questionable'),
    injury_reports.report_primary_injury as report_primary_injury
        with synonyms ('injury', 'what is he hurt with')
        comment = 'Primary injury named on the filed report, e.g. Knee, Hamstring.',
    injury_reports.report_secondary_injury as report_secondary_injury
        comment = 'Secondary injury named on the filed report, when one is listed.',
    injury_reports.practice_status as practice_status
        with synonyms ('practice participation line', 'practiced')
        comment = 'The filed practice participation line, e.g. Full Participation in Practice, Limited Participation in Practice, Did Not Participate In Practice.',
    injury_reports.practice_primary_injury as practice_primary_injury
        comment = 'Primary injury named on the practice line of the filed report.',
    injury_reports.modified_at as modified_at
        with synonyms ('report time', 'last updated')
        comment = 'When the filed report row was last modified.',
    injury_reports.modified_before_kickoff as modified_before_kickoff
        comment = 'True when the report was already in this state at kickoff. NULL when the row has no bridged game to compare against.',

    -- the depth chart: history, anchored to a game
    depth_charts.chart_source as chart_source
        comment = '''weekly'' is the league''s 2023-24 file, ''daily'' is 2025-onward snapshots. depth_slot and chart_as_of are NULL on weekly rows.'
        sample_values ('weekly', 'daily') is_enum,
    depth_charts.formation as formation
        comment = 'The unit or package the chart is drawn for: coarse on weekly rows (Offense, Defense, Special Teams), a package on daily rows (e.g. 3WR 1TE).',
    depth_charts.position as position
        with synonyms ('chart slot', 'depth chart position')
        comment = 'The chart slot such as LCB or RG, not the roster position.',
    depth_charts.depth_slot as depth_slot
        comment = 'Separates same-position slots on daily rows (the three WR spots). NULL on weekly rows.',
    depth_charts.depth_rank as depth_rank
        with synonyms ('depth', 'string')
        comment = 'Depth within the slot. 1 is the starter.',
    depth_charts.chart_as_of as chart_as_of
        comment = 'Date of the daily snapshot this row came from. NULL on weekly rows.',

    -- player identity
    players.full_name as full_name
        with synonyms ('player', 'player name')
        comment = 'Player full name.',
    players.position_name as position_name
        comment = 'Normalized roster position, e.g. Quarterback, Wide Receiver.',
    players.position_group as position_group
        comment = 'Coarse position group, e.g. Offense - Skill, Defense - Secondary.',

    -- player current status: Sleeper's as-of-now state, replaced daily.
    -- No history lives here; the filed history is injury_reports above.
    players.current_injury_status as injury_status
        with synonyms ('current status', 'status right now')
        comment = 'Sleeper''s current injury status for the player, as of the last daily load. As-of-now state replaced daily, no history. For a past week''s designation use report_status instead.',
    players.current_injury_body_part as injury_body_part
        comment = 'Body part on Sleeper''s current injury note. As-of-now state replaced daily, no history.',
    players.current_practice_participation as practice_participation
        comment = 'Sleeper''s current practice participation read. As-of-now state replaced daily, no history; the filed line per week is practice_status.',
    players.current_status_updated_at as news_updated_at
        comment = 'When Sleeper last updated this player''s status. As-of-now state replaced daily, no history.',
    players.current_depth_chart_position as depth_chart_position
        comment = 'Sleeper''s current depth chart position for the player. As-of-now state replaced daily, no history; the game-anchored chart is depth_charts.',
    players.current_depth_chart_order as depth_chart_order
        comment = 'Sleeper''s current depth chart order, 1 is the starter. As-of-now state replaced daily, no history.',
    players.is_active as is_active
        comment = 'Sleeper''s current active flag for the player.',

    -- team identity
    teams.team_abbreviation as team_abbreviation
        comment = 'Three-letter team code, e.g. KC, PHI, DET.'
        sample_values ('KC', 'PHI', 'DET', 'BUF'),
    teams.team_full_name as team_full_name
        with synonyms ('team')
        comment = 'Full team name, e.g. Kansas City Chiefs.'
        sample_values ('Kansas City Chiefs', 'Philadelphia Eagles', 'Detroit Lions'),
    teams.conference as conference
        comment = 'AFC or NFC.'
        sample_values ('AFC', 'NFC') is_enum,
    teams.division as division
        comment = 'Division within the conference. Uppercase in the data.'
        sample_values ('EAST', 'NORTH', 'SOUTH', 'WEST') is_enum,

    -- game context
    games.game_date as game_date
        comment = 'Calendar date of the anchored game.',
    games.season as season
        comment = 'NFL season of the anchored game.',
    games.week as week
        comment = 'Week of the anchored game within its season phase.',
    games.season_type_name as season_type_name
        comment = 'Preseason, Regular Season or Postseason for the anchored game.'
        sample_values ('Preseason', 'Regular Season', 'Postseason') is_enum,
    games.is_completed as is_completed
        comment = 'True when the anchored game has been played.'
)

metrics (
    injury_reports.report_count as count(injury_reports.injury_report_key)
        with synonyms ('number of reports', 'filed reports')
        comment = 'Number of filed injury report rows. A player can file multiple rows, so this over-counts players; use players_listed for people.',
    injury_reports.players_listed as count(distinct injury_reports.player_key)
        with synonyms ('players on the report', 'number of players listed')
        comment = 'Distinct players appearing on the filed injury report.',
    depth_charts.slot_count as count(depth_charts.depth_chart_key)
        comment = 'Number of depth chart slot rows. Grain is the chart slot, not the player.'
)

comment = 'NFL player availability from three clocks: the league''s official filed injury report (history, one row per filed report at season x week x team x player), the depth chart in effect at kickoff (history, one row per chart slot per team-game, weekly file for 2023-24 and daily snapshots from 2025), and Sleeper''s current player status (as-of-now, replaced daily, no history). The two facts are deliberately unrelated to each other. No statistics and no reported news live here.'

ai_sql_generation 'NEVER BLEND THE CLOCKS: the filed injury report is HISTORY anchored to a season and week; the players table''s current_* columns (injury_status, practice_participation, depth_chart_position, depth_chart_order, news_updated_at) are AS OF NOW, replaced daily with no history. Answer "what was his status for week N" only from injury_reports, answer "what is his status right now" only from the current_* columns, and never join or reconcile the two into one number.
WHO IS OUT FOR WEEK N: filter injury_reports with report_status = ''Out'' plus the season and week filters.
PRACTICE TRAJECTORY: questions about how a player trended through the week or across weeks read practice_status across injury report rows, ordered by week and modified_at.
DEPTH CHART DEFAULTS: for 2025 onward use chart_source = ''daily''. depth_rank = 1 is the starter.
GAME_KEY CAN BE NULL on injury report rows: filter reports by season and week, not by game.
GRAIN WARNING: report rows repeat per filed report and depth chart rows repeat per slot, so count people with count(distinct player_key), never by counting rows.'

ai_question_categorization 'Answer questions about filed injury reports, designation history, practice participation, depth charts and starters, and a player''s current status.
If the question asks what is being REPORTED or written about a player, beat-writer chatter, or why something happened, route it to NFLPlayerNewsAnalytics; this view holds official filings and status, not news.
If the question asks for production or usage statistics, route it to the player analytics tools.
If the question asks to PREDICT whether a player will play, decline the prediction and offer the player''s report trajectory (designations and practice status by week) instead.'

ai_verified_queries (
    team_injury_report_week as (
        question 'What is the Kansas City Chiefs injury report for week 5 of the 2025 season?'
        verified_at 1787788800
        onboarding_question true
        sql 'SELECT full_name, report_status, report_primary_injury, practice_status
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS players.full_name, injury_reports.report_status,
                          injury_reports.report_primary_injury,
                          injury_reports.practice_status,
                          teams.team_full_name,
                          injury_reports.season, injury_reports.week)
             WHERE team_full_name = ''Kansas City Chiefs''
               AND season = 2025 AND week = 5
             ORDER BY full_name'
    ),
    player_report_trajectory as (
        question 'How did Patrick Mahomes'' injury designation and practice status change week to week in 2025?'
        verified_at 1787788800
        sql 'SELECT week, report_status, practice_status
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS injury_reports.week, injury_reports.report_status,
                          injury_reports.practice_status,
                          players.full_name, injury_reports.season)
             WHERE full_name = ''Patrick Mahomes'' AND season = 2025
             ORDER BY week'
    ),
    depth_chart_starters as (
        question 'Who has been the Kansas City Chiefs starting quarterback on recent depth charts?'
        verified_at 1787788800
        sql 'SELECT full_name, position, chart_as_of
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS players.full_name, depth_charts.position,
                          depth_charts.depth_rank, depth_charts.chart_source,
                          depth_charts.chart_as_of, teams.team_full_name)
             WHERE team_full_name = ''Kansas City Chiefs''
               AND chart_source = ''daily''
               AND position = ''QB''
               AND depth_rank = 1
             ORDER BY chart_as_of DESC
             LIMIT 5'
    )
)
