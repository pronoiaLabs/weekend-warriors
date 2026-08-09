{{ config(materialized='semantic_view') }}

/*
    sv_nfl_team_performance -- team results and box score, one row per team per game.

    Grain: team x game (2,004 rows). Every row is one team's performance in one
    game, with the opponent available via opponent_team_key.

    Scope is deliberately tight (4 tables, ~50 exposed columns) because Cortex
    Analyst has a limited context window and focused views outperform broad ones.
    Player-level questions belong to sv_nfl_player_offense / _defense.

    fact_team_season (standings) is intentionally EXCLUDED. It also carries wins
    and losses, which would give Analyst two join paths to the same concept and
    cause multi-path ambiguity. Records are derivable here from win_count.
*/

tables (
    team_games as {{ ref('fact_team_game') }}
        primary key (team_game_key)
        with synonyms ('team games', 'game results', 'box score', 'team stats')
        comment = 'One row per team per game: result, scoring and full team box score. Grain is team x game, so a single game appears twice, once for each team. Covers preseason, regular season and postseason.',

    teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'The 32 NFL teams with conference and division.',

    opponents as {{ ref('dim_team') }}
        primary key (team_key)
        with synonyms ('opposing team', 'opponent')
        comment = 'The opposing team in a given game. Same table as teams, joined on opponent_team_key.',

    games as {{ ref('dim_game') }}
        primary key (game_key)
        comment = 'Game context: date, venue, season type and whether the game went to overtime. Scores are on team_games, not here.',

    weeks as {{ ref('dim_season_week') }}
        primary key (season_week_key)
        comment = 'The NFL calendar. Week 1 exists in both the preseason and the regular season, so season_type is part of this key.'
)

relationships (
    team_games_to_team as team_games (team_key) references teams (team_key),
    team_games_to_opponent as team_games (opponent_team_key) references opponents (team_key),
    team_games_to_game as team_games (game_key) references games (game_key),
    team_games_to_week as team_games (season_week_key) references weeks (season_week_key)
)

facts (
    team_games.points_scored as points_scored
        comment = 'Points this team scored in this game.',
    team_games.points_allowed as points_allowed
        comment = 'Points this team conceded in this game.',
    team_games.point_margin as point_margin
        comment = 'points_scored minus points_allowed. Negative in a loss.',
    team_games.win_flag as win_count
        comment = 'Additive 1/0 win indicator. Sum this to get wins.',
    team_games.loss_flag as loss_count
        comment = 'Additive 1/0 loss indicator. Sum this to get losses.',
    team_games.tie_flag as tie_count
        comment = 'Additive 1/0 tie indicator. NFL ties are rare but real.',
    team_games.total_yards as total_yards
        comment = 'Total offensive yards. NULL for 4 team-game rows with no box score.',
    team_games.rushing_yards as rushing_yards comment = 'Rushing yards gained.',
    team_games.net_passing_yards as net_passing_yards comment = 'Net passing yards, after sack losses.',
    team_games.first_downs as first_downs comment = 'Total first downs.',
    team_games.third_down_conversions as third_down_conversions comment = 'Third downs converted.',
    team_games.third_down_attempts as third_down_attempts comment = 'Third downs attempted.',
    team_games.fourth_down_conversions as fourth_down_conversions comment = 'Fourth downs converted.',
    team_games.fourth_down_attempts as fourth_down_attempts comment = 'Fourth downs attempted.',
    team_games.red_zone_scores as red_zone_scores comment = 'Red zone trips that resulted in a score.',
    team_games.red_zone_attempts as red_zone_attempts comment = 'Trips inside the opponent 20.',
    team_games.turnovers as turnovers comment = 'Turnovers committed: fumbles lost plus interceptions thrown.',
    team_games.interceptions_thrown as interceptions_thrown comment = 'Interceptions thrown by this team.',
    team_games.fumbles_lost as fumbles_lost comment = 'Fumbles lost to the opponent.',
    team_games.sacks_allowed as sacks_allowed comment = 'Times this team''s quarterback was sacked.',
    team_games.penalties as penalties comment = 'Penalties accepted against this team.',
    team_games.penalty_yards as penalty_yards comment = 'Yards lost to penalties.',
    team_games.possession_time_seconds as possession_time_seconds
        comment = 'Time of possession in seconds. Roughly 1800 per team per game.',
    team_games.total_offensive_plays as total_offensive_plays comment = 'Offensive plays run.',
    team_games.total_drives as total_drives comment = 'Offensive drives.'
)

dimensions (
    -- who
    teams.team_abbreviation as team_abbreviation
        comment = 'Three-letter team code, e.g. KC, PHI, DET.'
        sample_values ('KC', 'PHI', 'DET', 'BUF', 'SF', 'DAL', 'BAL', 'CIN'),
    teams.team_full_name as team_full_name
        comment = 'Full team name, e.g. Kansas City Chiefs.'
        sample_values ('Kansas City Chiefs', 'Philadelphia Eagles', 'Detroit Lions', 'Buffalo Bills'),
    teams.conference as conference
        with synonyms ('afc or nfc', 'league conference')
        comment = 'AFC or NFC.'
        sample_values ('AFC', 'NFC') is_enum,
    teams.division as division
        comment = 'Division within the conference. Uppercase in the data.'
        sample_values ('EAST', 'NORTH', 'SOUTH', 'WEST') is_enum,
    teams.conference_division as conference_division
        comment = 'Conference and division combined, e.g. AFC WEST.'
        sample_values ('AFC WEST', 'NFC EAST', 'AFC NORTH', 'NFC SOUTH'),

    -- against whom
    opponents.opponent_abbreviation as team_abbreviation
        with synonyms ('opponent code', 'against')
        comment = 'Three-letter code of the opposing team.'
        sample_values ('KC', 'PHI', 'DET', 'BUF'),
    opponents.opponent_full_name as team_full_name
        comment = 'Full name of the opposing team.'
        sample_values ('Kansas City Chiefs', 'Philadelphia Eagles'),

    -- when
    weeks.season as season
        comment = 'NFL season. A season starting in year N runs through February of N+1, so the 2025 season ends in Feb 2026. Currently covers 2023 to 2025; new seasons are added as they load.',
    weeks.week as week
        comment = 'Week within the season phase. Regular season is weeks 1 to 18. Week numbers restart for preseason and postseason, so always pair week with season_type.',
    weeks.season_type as season_type_name
        with synonyms ('phase', 'part of season', 'regular or playoff')
        comment = 'Preseason, Regular Season or Postseason. Almost all questions mean Regular Season.'
        sample_values ('Preseason', 'Regular Season', 'Postseason') is_enum,
    weeks.season_week_label as season_week_label
        comment = 'Human readable week, e.g. 2024 W9 or 2024 Post W1.'
        sample_values ('2024 W9', '2025 W1', '2024 Post W1'),
    games.game_date as game_date
        comment = 'Calendar date the game was played.',

    -- where and what kind
    games.venue as venue
        comment = 'Stadium name. 40 distinct venues in the data.'
        sample_values ('Arrowhead Stadium', 'Lincoln Financial Field', 'Ford Field'),
    games.went_to_overtime as went_to_overtime
        comment = 'True if the game required overtime.'
        ,
    team_games.is_home as is_home
        with synonyms ('home or away', 'at home', 'home game')
        comment = 'True when this team was the home team. Use for home and away splits.'
        ,
    team_games.has_box_score as has_box_score
        comment = 'False for 4 team-game rows whose game has no box score. Result columns are still populated for those rows; every box score measure is NULL.'
        
)

metrics (
    -- volume
    team_games.games_played as count(team_games.team_game_key)
        comment = 'Number of team-games. One game contributes 1 to each team.',

    -- record
    team_games.wins as sum(team_games.win_flag)
        comment = 'Games won.',
    team_games.losses as sum(team_games.loss_flag)
        comment = 'Games lost.',
    team_games.ties as sum(team_games.tie_flag)
        comment = 'Games tied. Common in preseason, which has no overtime.',
    team_games.win_pct as (sum(team_games.win_flag) + 0.5 * sum(team_games.tie_flag))
                          / nullif(count(team_games.team_game_key), 0)
        with synonyms ('winning percentage', 'win rate', 'win percentage')
        comment = 'NFL winning percentage: a tie counts as half a win. (W + 0.5T) / games.',

    -- scoring
    team_games.total_points_scored as sum(team_games.points_scored)
        with synonyms ('points for', 'total points')
        comment = 'Total points scored.',
    team_games.total_points_allowed as sum(team_games.points_allowed)
        with synonyms ('points against', 'points conceded')
        comment = 'Total points allowed.',
    team_games.avg_points_scored as avg(team_games.points_scored)
        with synonyms ('points per game', 'scoring average')
        comment = 'Average points scored per game.',
    team_games.avg_points_allowed as avg(team_games.points_allowed)
        with synonyms ('points allowed per game', 'defensive scoring average')
        comment = 'Average points allowed per game.',
    team_games.point_differential as sum(team_games.point_margin)
        with synonyms ('point diff', 'margin', 'net points')
        comment = 'Total points scored minus points allowed.',

    -- offense
    team_games.total_yards_gained as sum(team_games.total_yards)
        comment = 'Total offensive yards.',
    team_games.avg_yards_per_game as avg(team_games.total_yards)
        with synonyms ('yards per game', 'offensive average')
        comment = 'Average total yards per game.',
    team_games.total_rushing_yards as sum(team_games.rushing_yards)
        comment = 'Total rushing yards.',
    team_games.total_passing_yards as sum(team_games.net_passing_yards)
        comment = 'Total net passing yards.',
    team_games.total_first_downs as sum(team_games.first_downs)
        comment = 'Total first downs.',

    -- efficiency. Ratios are computed as sum over sum, never as an average of
    -- per-game rates, which would weight a 1-for-2 game the same as 8-for-14.
    team_games.third_down_pct as sum(team_games.third_down_conversions)
                                 / nullif(sum(team_games.third_down_attempts), 0)
        with synonyms ('third down rate', 'third down efficiency', 'third down conversion rate')
        comment = 'Third down conversion rate, computed as total conversions over total attempts.',
    team_games.fourth_down_pct as sum(team_games.fourth_down_conversions)
                                  / nullif(sum(team_games.fourth_down_attempts), 0)
        comment = 'Fourth down conversion rate.',
    team_games.red_zone_pct as sum(team_games.red_zone_scores)
                               / nullif(sum(team_games.red_zone_attempts), 0)
        with synonyms ('red zone rate', 'red zone efficiency', 'red zone scoring rate')
        comment = 'Share of red zone trips that produced a score.',
    team_games.yards_per_play_calc as sum(team_games.total_yards)
                                      / nullif(sum(team_games.total_offensive_plays), 0)
        with synonyms ('yards per play', 'efficiency per play')
        comment = 'Total yards divided by total offensive plays.',

    -- mistakes and control
    team_games.total_turnovers as sum(team_games.turnovers)
        with synonyms ('giveaways', 'turnovers committed')
        comment = 'Turnovers committed: fumbles lost plus interceptions thrown.',
    team_games.total_interceptions_thrown as sum(team_games.interceptions_thrown)
        comment = 'Interceptions thrown.',
    team_games.total_fumbles_lost as sum(team_games.fumbles_lost)
        comment = 'Fumbles lost.',
    team_games.total_sacks_allowed as sum(team_games.sacks_allowed)
        with synonyms ('sacks given up', 'quarterback sacked')
        comment = 'Times this team''s quarterback was sacked. This is sacks ALLOWED by this offense, not sacks recorded by its defense.',
    team_games.total_penalties as sum(team_games.penalties)
        comment = 'Penalties accepted against this team.',
    team_games.total_penalty_yards as sum(team_games.penalty_yards)
        comment = 'Yards lost to penalties.',
    team_games.avg_possession_minutes as avg(team_games.possession_time_seconds) / 60
        with synonyms ('time of possession', 'possession time', 'ball control')
        comment = 'Average time of possession per game, in minutes.'
)

comment = 'NFL team performance at team-by-game grain, 2023 to 2025 seasons. Each row is one team in one game with its result and full box score, so a single game appears twice. Use this for team records, scoring, offensive efficiency, home and away splits, and opponent analysis. Does NOT contain individual player statistics or play-by-play detail.'

ai_sql_generation 'DEFAULT TO REGULAR SEASON: unless the user explicitly says preseason, postseason, playoffs, or all games, always filter season_type = ''Regular Season''. Preseason results are not meaningful and including them corrupts records and averages.
DEFAULT SEASON: if no season is given, use the most recent season present in the data. Determine that from the data rather than assuming a year.
RECORDS: express a team record as wins-losses, and append ties only when ties is greater than zero (for example 15-2, or 9-7-1). A tie counts as half a win in win_pct.
RATES: always compute conversion and efficiency rates as a sum over a sum, never as an average of per-game percentages. Round percentages to one decimal place and present them as percentages.
YARDS AND POINTS: report as whole numbers.
SACKS: total_sacks_allowed counts sacks this team''s offense gave up. This view has no defensive sack counts; if the user asks how many sacks a defense recorded, say this view does not contain it.
GRAIN WARNING: the grain is team x game, so counting rows counts team-games, not games. To count distinct games use count(distinct game_key).
HOME AND AWAY: use is_home for splits rather than comparing team to opponent.
BOX SCORE GAPS: four team-game rows have has_box_score = false and NULL box score measures. Results are still valid for those rows, so do not filter them out of record or scoring questions.'

ai_question_categorization 'Answer questions about team results, records, scoring, offensive efficiency, penalties, turnovers, time of possession, and home or away and opponent splits.
If the question is about an INDIVIDUAL PLAYER''s statistics (passing, rushing, receiving, tackles, sacks, kicking), mark it out of scope and tell the user that player statistics live in the player semantic views, not this one.
If the question asks for PLAY-BY-PLAY or situational detail about specific plays, downs, or win probability, mark it out of scope and point the user to the play-level view.
If the question asks about DEFENSIVE sacks, tackles, or interceptions recorded by a defense, explain that this view only carries sacks and turnovers from the offense''s perspective.
If the question names a season that is not present in the data, say which seasons are actually available rather than assuming a fixed range.
If a team is named ambiguously (for example just a city that has moved, or a nickname shared across leagues), ask the user to confirm which team they mean.'
