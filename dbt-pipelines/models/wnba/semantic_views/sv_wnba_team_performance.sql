{{ config(materialized='semantic_view') }}

/*
    sv_wnba_team_performance -- team results and box score, one row per team per game.

    Grain: team x game (478 rows = 239 decided games x 2 teams), 2026 season.
    Every row is one team's performance in one game, with the opponent
    available via opponent_team_key.

    Scope is deliberately tight (4 tables, ~54 exposed columns) because Cortex
    Analyst has a limited context window and focused views outperform broad
    ones. Player-level questions belong to sv_wnba_player_performance and
    sv_wnba_player_advanced; anything spanning more than the 2026 season
    belongs to sv_wnba_team_history.

    fact_wnba_team_season (standings) is intentionally EXCLUDED, exactly as
    fact_team_season is on the NFL side. It also carries wins and losses, which
    would give Analyst two join paths to the same concept and cause multi-path
    ambiguity. Records are derivable here from win_count. It is also a
    mid-season snapshot that trails this game log by a day or two, so the two
    would disagree by construction.

    THE STORED PERCENTAGE COLUMNS ARE NOT EXPOSED. fact_wnba_team_game carries
    field_goal_pct, three_point_pct and free_throw_pct straight from the source
    on a 0-100 scale (46.2, not 0.462), which is the opposite convention from
    every other WNBA fact in the mart. Rather than publish one view with two
    scales in it, those three columns are dropped and the same three rates are
    published as sum-over-sum METRICS on a 0-1 fraction scale, matching
    sv_wnba_team_history and sv_wnba_player_advanced. Sum over sum is the
    correct computation anyway: averaging per-game percentages weights a
    2-for-5 quarter the same as an 11-for-20 night.

    NO TIE COLUMNS. Basketball has none. An equal score means the game produced
    no result and it is already filtered out of the fact, so records here are
    always W-L and never W-L-T.

    THE POSTPONED GAME IS ALREADY GONE. Game 24935 on 2026-07-17 carries STATUS
    'post' with a fake 0-0 line and two all-zero box scores. fact_wnba_team_game
    filters on winner_team_id being present, so it never reaches this view and
    no rule about it is needed here.
*/

tables (
    team_games as {{ ref('fact_wnba_team_game') }}
        primary key (team_game_key)
        with synonyms ('team games', 'game results', 'box score', 'team stats')
        comment = 'One row per team per game: result, scoring and full team box score. Grain is team x game, so a single game appears twice, once for each team. 2026 season only. Covers the regular season plus the one All-Star game.',

    teams as {{ ref('dim_wnba_team') }}
        primary key (team_key)
        comment = 'Every team the source references, 35 rows, of which 17 are franchises. The rest are All-Star squads, national sides and placeholders, kept because the All-Star game references them by id. Filter on is_franchise for league questions.',

    opponents as {{ ref('dim_wnba_team') }}
        primary key (team_key)
        with synonyms ('opposing team', 'opponent')
        comment = 'The opposing team in a given game. Same table as teams, joined on opponent_team_key.',

    games as {{ ref('dim_wnba_game') }}
        primary key (game_key)
        comment = 'Game context: date, season, season type and whether the game went to overtime. Scores are on team_games, not here.'
)

relationships (
    team_games_to_team as team_games (team_key) references teams (team_key),
    team_games_to_opponent as team_games (opponent_team_key) references opponents (team_key),
    team_games_to_game as team_games (game_key) references games (game_key)
)

facts (
    -- result
    team_games.points_scored as points_scored
        comment = 'Points this team scored in this game. Comes from the game record, not the box score, which carries no points column.',
    team_games.points_allowed as points_allowed
        comment = 'Points this team conceded in this game.',
    team_games.point_margin as point_margin
        comment = 'points_scored minus points_allowed. Negative in a loss. Never zero, because a drawn game produces no result and is not in the data.',
    team_games.win_flag as win_count
        comment = 'Additive 1/0 win indicator. Sum this to get wins.',
    team_games.loss_flag as loss_count
        comment = 'Additive 1/0 loss indicator. Sum this to get losses. There is no tie counterpart.',

    -- shooting volume. Makes and attempts only; rates are metrics.
    team_games.field_goals_made as field_goals_made
        comment = 'Field goals made, including three pointers. NULL for the 4 team-game rows with no box score.',
    team_games.field_goals_attempted as field_goals_attempted
        comment = 'Field goals attempted, including three pointers.',
    team_games.three_pointers_made as three_pointers_made
        comment = 'Three pointers made. A subset of field_goals_made.',
    team_games.three_pointers_attempted as three_pointers_attempted
        comment = 'Three pointers attempted. A subset of field_goals_attempted.',
    team_games.free_throws_made as free_throws_made
        comment = 'Free throws made.',
    team_games.free_throws_attempted as free_throws_attempted
        comment = 'Free throws attempted.',

    -- rebounding
    team_games.offensive_rebounds as offensive_rebounds
        comment = 'Rebounds collected at the offensive end.',
    team_games.defensive_rebounds as defensive_rebounds
        comment = 'Rebounds collected at the defensive end.',
    team_games.rebounds as rebounds
        comment = 'Total rebounds. This is the source''s own total and is not recomputed from the offensive and defensive splits.',

    -- playmaking, defence and mistakes
    team_games.assists as assists
        comment = 'Assists recorded by this team.',
    team_games.steals as steals
        comment = 'Steals recorded by this team. A steal is a turnover this team FORCED, so it is the closest thing here to a takeaway.',
    team_games.blocks as blocks
        comment = 'Shots blocked by this team.',
    team_games.turnovers as turnovers
        comment = 'Turnovers COMMITTED by this team, not forced. Turnovers forced sit on the opponent''s row.',
    team_games.personal_fouls as personal_fouls
        comment = 'Personal fouls committed by this team.'
)

dimensions (
    -- who
    teams.team_abbreviation as team_abbreviation
        comment = 'Short team code, two or three letters, e.g. LV, NY, MIN.'
        sample_values ('LV', 'NY', 'MIN', 'PHX', 'SEA', 'IND', 'ATL', 'CON'),
    teams.team_full_name as team_full_name
        comment = 'Full team name, e.g. Las Vegas Aces. The two 2026 expansion clubs read as just Fire and Tempo, without a city, because that is how the source spells them.'
        sample_values ('Las Vegas Aces', 'New York Liberty', 'Minnesota Lynx', 'Indiana Fever', 'Phoenix Mercury'),
    teams.conference as conference
        with synonyms ('east or west', 'league conference')
        comment = 'Eastern Conference or Western Conference. NULL for the two 2026 expansion clubs (Fire, Tempo) and for every non-franchise row, so a conference filter silently drops them. For a season-accurate conference use the team history view.'
        sample_values ('Eastern Conference', 'Western Conference') is_enum,
    teams.is_franchise as is_franchise
        comment = 'True for the 17 real franchises. False for All-Star squads and placeholder rows. Filter on this for any league-wide question.',

    -- against whom
    opponents.opponent_abbreviation as team_abbreviation
        with synonyms ('opponent code', 'against')
        comment = 'Short code of the opposing team.'
        sample_values ('LV', 'NY', 'MIN', 'PHX', 'SEA'),
    opponents.opponent_full_name as team_full_name
        comment = 'Full name of the opposing team.'
        sample_values ('Las Vegas Aces', 'New York Liberty', 'Minnesota Lynx'),

    -- when
    games.season as season
        comment = 'WNBA season. This view holds 2026 only. Season-over-season questions need the team history view, which is the only multi-year source in the set.',
    games.season_type_name as season_type_name
        with synonyms ('phase', 'part of season', 'regular or all-star')
        comment = 'Four-way classification: Regular Season, All-Star, Postseason, Preseason. Only Regular Season (476 rows) and All-Star (2 rows) are present today. Almost all questions mean Regular Season.'
        sample_values ('Regular Season', 'All-Star'),
    games.game_date as game_date
        comment = 'Calendar date the game was played. Decided games run from 2026-05-08 to 2026-08-08.',
    games.went_to_overtime as went_to_overtime
        comment = 'True if the game required overtime. 10 games so far.',

    -- what kind
    team_games.is_home as is_home
        with synonyms ('home or away', 'at home', 'home game')
        comment = 'True when this team was the home team. Use for home and away splits rather than comparing team to opponent.',
    team_games.has_box_score as has_box_score
        comment = 'False for 4 team-game rows, the two 2026-08-08 games whose box score has not loaded yet. The result columns are still populated for those rows; every box score measure is NULL.'
)

metrics (
    -- volume
    team_games.games_played as count(team_games.team_game_key)
        with synonyms ('games', 'number of games')
        comment = 'Number of team-games. One game contributes 1 to each of the two teams in it, so this is not a count of games.',

    -- record. No tie term exists in basketball.
    team_games.wins as sum(team_games.win_flag)
        comment = 'Games won.',
    team_games.losses as sum(team_games.loss_flag)
        comment = 'Games lost.',
    team_games.win_pct as sum(team_games.win_flag)
                         / nullif(count(team_games.team_game_key), 0)
        with synonyms ('winning percentage', 'win rate', 'win percentage')
        comment = 'Wins divided by games played, a 0-1 fraction. There is no tie term: basketball has no ties, so this is never (W + 0.5T) / games the way the NFL view computes it.',

    -- scoring
    team_games.total_points_scored as sum(team_games.points_scored)
        with synonyms ('points for', 'total points')
        comment = 'Total points scored.',
    team_games.total_points_allowed as sum(team_games.points_allowed)
        with synonyms ('points against', 'points conceded')
        comment = 'Total points allowed.',
    team_games.avg_points_scored as avg(team_games.points_scored)
        with synonyms ('points per game', 'ppg', 'scoring average')
        comment = 'Average points scored per game.',
    team_games.avg_points_allowed as avg(team_games.points_allowed)
        with synonyms ('opponent points per game', 'points allowed per game', 'defensive rating in points')
        comment = 'Average points allowed per game. This is the opponent''s scoring average against this team.',
    team_games.point_differential as sum(team_games.point_margin)
        with synonyms ('point diff', 'net points')
        comment = 'Total points scored minus points allowed.',
    team_games.avg_point_margin as avg(team_games.point_margin)
        with synonyms ('average margin', 'margin of victory', 'net rating in points')
        comment = 'Average scoring margin per game. Negative for a team outscored on the season.',

    -- shooting efficiency. Sum over sum, never an average of per-game rates.
    team_games.field_goal_pct_calc as sum(team_games.field_goals_made)
                                      / nullif(sum(team_games.field_goals_attempted), 0)
        with synonyms ('field goal percentage', 'fg%', 'shooting percentage')
        comment = 'Field goal percentage, computed as total makes over total attempts. A 0-1 fraction; multiply by 100 to display.',
    team_games.three_point_pct_calc as sum(team_games.three_pointers_made)
                                       / nullif(sum(team_games.three_pointers_attempted), 0)
        with synonyms ('three point percentage', '3p%', 'from beyond the arc')
        comment = 'Three point percentage, computed as total makes over total attempts. A 0-1 fraction.',
    team_games.free_throw_pct_calc as sum(team_games.free_throws_made)
                                      / nullif(sum(team_games.free_throws_attempted), 0)
        with synonyms ('free throw percentage', 'ft%', 'from the line')
        comment = 'Free throw percentage, computed as total makes over total attempts. A 0-1 fraction.',
    team_games.effective_field_goal_pct_calc as (sum(team_games.field_goals_made)
                                                 + 0.5 * sum(team_games.three_pointers_made))
                                                / nullif(sum(team_games.field_goals_attempted), 0)
        with synonyms ('efg', 'effective field goal percentage')
        comment = 'Effective field goal percentage, which credits a three pointer as 1.5 makes. A 0-1 fraction.',

    -- rebounding, playmaking and mistakes, per game
    team_games.rebounds_per_game as avg(team_games.rebounds)
        with synonyms ('rpg', 'boards per game')
        comment = 'Average total rebounds per game. The 4 rows with no box score are NULL and are ignored by the average.',
    team_games.offensive_rebounds_per_game as avg(team_games.offensive_rebounds)
        comment = 'Average offensive rebounds per game.',
    team_games.assists_per_game as avg(team_games.assists)
        with synonyms ('apg', 'ball movement')
        comment = 'Average assists per game.',
    team_games.steals_per_game as avg(team_games.steals)
        with synonyms ('spg')
        comment = 'Average steals per game. Steals are turnovers this team forced.',
    team_games.blocks_per_game as avg(team_games.blocks)
        with synonyms ('bpg')
        comment = 'Average blocks per game.',
    team_games.turnovers_per_game as avg(team_games.turnovers)
        with synonyms ('giveaways per game')
        comment = 'Average turnovers COMMITTED per game.',
    team_games.total_turnovers as sum(team_games.turnovers)
        with synonyms ('giveaways', 'turnovers committed')
        comment = 'Total turnovers committed by this team. This view carries no turnovers-forced column: the opponent''s committed turnovers are on the opponent''s own row.',
    team_games.personal_fouls_per_game as avg(team_games.personal_fouls)
        with synonyms ('fouls per game')
        comment = 'Average personal fouls committed per game.'
)

comment = 'WNBA team performance at team-by-game grain, 2026 season. Each row is one team in one game with its result and full team box score, so a single game appears twice. 478 rows over 239 decided games. Use this for team records, scoring, shooting efficiency, rebounding, home and away splits and opponent analysis within the current season. Does NOT contain individual player statistics, play-by-play detail, seasons before 2026, standings positions or playoff seeds, shot-location data, or any turnovers-forced column.'

ai_sql_generation 'DEFAULT TO REGULAR SEASON: unless the user explicitly says All-Star, exhibition, or all games, always filter season_type_name = ''Regular Season''. This excludes the All-Star game and any preseason exhibition, whose rosters are All-Star squads rather than franchises and whose results would corrupt records and averages.
SEASON COVERAGE: this view holds the 2026 season only. If the user asks about any other season, or about a trend across seasons, say so and point them to the team history view rather than returning an empty result.
COMMISSIONER''S CUP: Commissioner''s Cup group-stage games count in the standings and are indistinguishable from ordinary regular-season games in this source. There is no flag for them, so they are always included and cannot be isolated. Say this rather than guessing.
RECORDS: express a team record as wins-losses, for example 20-8. NEVER append a third number for ties. Basketball has no ties, a drawn game produces no result, and there is no tie column anywhere in this view.
RATES: always compute shooting and efficiency rates as a sum over a sum, never as an average of per-game percentages, which would weight a 5-attempt night the same as a 20-attempt night. Every rate metric here is already written that way.
PERCENTAGE SCALE: every rate metric in this view returns a 0 to 1 fraction. Multiply by 100 and round to one decimal place when presenting, for example 0.462 shown as 46.2%. Points, rebounds, assists and other counts are whole numbers, except per-game averages which take one decimal place.
TURNOVER DIRECTION: the turnovers fact and the total_turnovers and turnovers_per_game metrics are turnovers this team COMMITTED. This view has no turnovers-forced column. To answer how many turnovers a team FORCED, read the turnovers on its OPPONENTS'' rows, which means grouping by opponent_abbreviation rather than team_abbreviation. Turnover margin therefore needs both sides and cannot be read off one row. steals_per_game is the nearest single-row proxy and is not the same thing, so do not present it as turnovers forced.
GRAIN WARNING: the grain is team x game, so every game contributes TWO rows, one per team. Counting rows counts team-games and not games. To count distinct games use count(distinct game_key). A league-wide total of points scored is double the points actually put on scoreboards only if you forget that each row is one team, so state which you mean.
FRANCHISES ONLY: for any league-wide ranking or leaderboard, filter is_franchise = true. The team dimension also holds All-Star squads and placeholder rows.
CONFERENCE GAPS: conference is NULL for the two 2026 expansion clubs, Fire and Tempo, because the team dimension carries only original-franchise conferences. A conference filter silently drops them. If a conference question is asked, say which teams were excluded.
HOME AND AWAY: use is_home for splits rather than comparing team to opponent.
BOX SCORE GAPS: 4 team-game rows have has_box_score = false and NULL box score measures, the two 2026-08-08 games whose box score has not loaded. Results are still valid for those rows, so do not filter them out of record or scoring questions.'

ai_question_categorization 'Answer questions about 2026 WNBA team results, records, scoring, shooting efficiency, rebounding, assists, steals, blocks, turnovers, fouls, and home or away and opponent splits at the game level.
If the question spans MORE THAN THE 2026 SEASON, asks about franchise history, a year-over-year trend, standings position, games behind, or playoff seeding, mark it out of scope and route it to WNBATeamHistoryAnalytics, which is the only multi-season view in this set.
If the question is about an INDIVIDUAL PLAYER''s box score production (points, rebounds, assists, steals, blocks, minutes, plus-minus), mark it out of scope and route it to WNBAPlayerPerformanceAnalytics.
If the question asks for PLAYER EFFICIENCY or advanced metrics such as PIE, usage rate, true shooting, offensive or defensive rating, or pace, mark it out of scope and route it to WNBAPlayerAdvancedAnalytics.
If the question asks for SHOT LOCATION or distance-based shooting (shots from the paint, by zone, from five feet out), explain that zone shooting data exists in the warehouse but is not exposed in any semantic view, so it cannot be answered here.
If the question asks for PLAY-BY-PLAY or possession-level detail, explain that this source carries no play data at all.
If the question asks how many turnovers a team FORCED, or for turnover margin, clarify that this view records turnovers committed only and explain that forced turnovers must be read from the opponents'' rows.
If the question names a season other than 2026, say that this view covers 2026 only and name WNBATeamHistoryAnalytics as the place season history lives.
If a team is named ambiguously, for example by city alone where the city has more than one professional side, or by a nickname shared with another league, ask the user to confirm which team they mean.'
