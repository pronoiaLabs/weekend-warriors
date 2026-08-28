{{ config(materialized='semantic_view') }}

/*
    sv_nfl_team_performance -- team results, box score and EPA efficiency,
    one row per team per game, seen from both sides of the ball.

    Grain: team x game (2,004 rows). team_games is the offense side: the
    result, the team's own box score, and the nflverse EPA block. team_defense
    is its 1:1 twin on team_game_key, carrying the allowed side: the opponent
    box re-read (yards and conversions surrendered), the player-rollup
    pressure counts (takeaways, sacks recorded), and EPA allowed. Every
    efficiency metric here is a ratio of the additive counts, never an
    average of a per-game rate.

    Scope stays deliberately tight because Cortex Analyst has a limited
    context window and focused views outperform broad ones. Player-level
    questions belong to sv_nfl_player_offense / _defense; situational splits
    by down, distance, field zone or game script belong to the team
    situation view.

    fact_team_season (standings) is intentionally EXCLUDED. It also carries wins
    and losses, which would give Analyst two join paths to the same concept and
    cause multi-path ambiguity. Records are derivable here from win_count.
*/

tables (
    team_games as {{ ref('fact_team_game_offense') }}
        primary key (team_game_key)
        with synonyms ('team games', 'game results', 'box score', 'team stats')
        comment = 'One row per team per game: result, scoring and full team box score. Grain is team x game, so a single game appears twice, once for each team. Covers preseason, regular season and postseason.',

    team_defense as {{ ref('fact_team_game_defense') }}
        primary key (team_game_key)
        with synonyms ('team defense', 'defense allowed', 'defensive stats', 'yards allowed')
        comment = 'The allowed side of the same team-game: the opponent''s box score re-read from this team''s perspective, player-rollup pressure counts (takeaways, sacks recorded), and EPA allowed. 1:1 twin of team_games on team_game_key.',

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
    team_games_to_week as team_games (season_week_key) references weeks (season_week_key),
    -- team_defense reaches every dimension THROUGH team_games (its 1:1 twin),
    -- deliberately: the relationship graph must stay a tree. Direct edges from
    -- team_defense to the dims would give the dims two paths from each fact,
    -- and SEMANTIC_VIEW() rejects any multi-path dimension resolution
    -- (measured 2026-08-28; the two-hop path resolves fine).
    defense_to_offense as team_defense (team_game_key) references team_games (team_game_key)
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
    team_games.total_drives as total_drives comment = 'Offensive drives.',

    -- nflverse EPA block, offense side. All additive counts and EPA sums:
    -- re-aggregate rates from these, never from any per-game rate column.
    -- NULL on preseason rows, where nflverse publishes no play-by-play.
    team_games.off_plays as off_plays
        comment = 'Scrimmage plays run by this offense (pass or run with a non-NULL EPA). Additive; NULL on preseason rows (nflverse publishes no preseason play-by-play).',
    team_games.off_epa as off_epa
        comment = 'Total expected points added by this offense across its scrimmage plays. Additive; NULL on preseason rows. Re-aggregate rates from this and off_plays, never from a per-game rate.',
    team_games.dropbacks as dropbacks
        comment = 'Pass plays (dropbacks) by this offense. Additive; NULL on preseason rows.',
    team_games.pass_epa as pass_epa
        comment = 'Total EPA on this offense''s pass plays. Additive; NULL on preseason rows.',
    team_games.epa_carries as carries
        comment = 'nflverse scrimmage carries (rush plays with an EPA value), distinct from the box score''s rushing_attempts. Additive; NULL on preseason rows.',
    team_games.rush_epa as rush_epa
        comment = 'Total EPA on this offense''s rush plays. Additive; NULL on preseason rows.',
    team_games.success_plays as success_plays
        comment = 'Scrimmage plays graded successful (positive EPA). Additive; NULL on preseason rows. Divide by off_plays for success rate, never average a rate column.',
    team_games.explosive_plays as explosive_plays
        comment = 'Explosive plays: passes of 20+ yards or rushes of 10+ yards. Additive; NULL on preseason rows.',
    team_games.early_down_plays as early_down_plays
        comment = 'Scrimmage plays on first or second down. Additive; NULL on preseason rows.',
    team_games.early_down_success_plays as early_down_success_plays
        comment = 'Successful plays on first or second down. Additive; NULL on preseason rows.',
    team_games.pass_over_expected_sum as pass_over_expected_sum
        comment = 'Sum of pass minus expected-pass probability over plays with an xpass model value: the PROE numerator. Additive; NULL on preseason rows.',
    team_games.xpass_plays as xpass_plays
        comment = 'Plays with an xpass model value: the PROE denominator. Additive; NULL on preseason rows.',

    -- team_defense: EPA allowed (same additive contract, NULL on preseason
    -- rows -- nflverse publishes no preseason play-by-play), takeaways and
    -- pressure, and the opponent box score re-read as the allowed side.
    team_defense.def_plays as def_plays
        comment = 'Opponent scrimmage plays this defense faced. Additive; NULL on preseason rows. Re-aggregate rates from these counts, never from per-game rates.',
    team_defense.def_epa as def_epa
        comment = 'Total EPA allowed by this defense. Additive; NULL on preseason rows. Negative is good for the defense.',
    team_defense.def_dropbacks_faced as def_dropbacks_faced
        comment = 'Opponent dropbacks this defense faced. Additive; NULL on preseason rows.',
    team_defense.def_pass_epa as def_pass_epa
        comment = 'EPA allowed on opponent pass plays. Additive; NULL on preseason rows.',
    team_defense.def_carries_faced as def_carries_faced
        comment = 'Opponent scrimmage carries this defense faced. Additive; NULL on preseason rows.',
    team_defense.def_rush_epa as def_rush_epa
        comment = 'EPA allowed on opponent rush plays. Additive; NULL on preseason rows.',
    team_defense.def_success_plays as def_success_plays
        comment = 'Opponent plays graded successful against this defense. Additive; NULL on preseason rows.',
    team_defense.def_explosive_plays as def_explosive_plays
        comment = 'Explosive plays allowed: opponent passes of 20+ yards or rushes of 10+ yards. Additive; NULL on preseason rows.',
    team_defense.def_early_down_plays as def_early_down_plays
        comment = 'Opponent plays faced on first or second down. Additive; NULL on preseason rows.',
    team_defense.def_early_down_success_plays as def_early_down_success_plays
        comment = 'Opponent early-down plays graded successful. Additive; NULL on preseason rows.',
    team_defense.def_pass_over_expected_sum as def_pass_over_expected_sum
        comment = 'Sum of opponent pass minus expected-pass probability: the PROE-faced numerator. Additive; NULL on preseason rows.',
    team_defense.def_xpass_plays as def_xpass_plays
        comment = 'Opponent plays with an xpass model value: the PROE-faced denominator. Additive; NULL on preseason rows.',
    team_defense.takeaways as takeaways
        comment = 'Takeaways forced: the opponent''s turnovers (fumbles lost plus interceptions thrown). Never derived from fumble recoveries, which also count own-fumble recoveries.',
    team_defense.sacks_recorded as sacks_recorded
        comment = 'Sacks credited to this defense''s players, rolled up from the player box score. FLOAT half-sacks, so fractional values are real. Sacks BY this defense, not sacks its offense allowed.',
    team_defense.opp_total_yards as opp_total_yards
        comment = 'Total yards allowed: the opponent''s offensive yards in this game.',
    team_defense.opp_rushing_yards as opp_rushing_yards
        comment = 'Rushing yards allowed.',
    team_defense.opp_net_passing_yards as opp_net_passing_yards
        comment = 'Net passing yards allowed, after sack losses.',
    team_defense.opp_third_down_conversions as opp_third_down_conversions
        comment = 'Third downs the opponent converted against this defense.',
    team_defense.opp_third_down_attempts as opp_third_down_attempts
        comment = 'Third downs the opponent attempted against this defense.',
    team_defense.opp_red_zone_scores as opp_red_zone_scores
        comment = 'Opponent red zone trips that produced a score.',
    team_defense.opp_red_zone_attempts as opp_red_zone_attempts
        comment = 'Opponent trips inside this team''s 20.'
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
        ,
    team_games.has_nflverse as has_nflverse
        comment = 'True when the nflverse EPA block covers this row. False on preseason rows, where nflverse publishes no play-by-play and every EPA, success, explosive and PROE column is NULL.'

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
        comment = 'Average time of possession per game, in minutes.',

    -- offensive efficiency (nflverse EPA). Every rate is a ratio of the
    -- additive facts above; preseason rows contribute NULL, never zero.
    team_games.off_epa_per_play as sum(team_games.off_epa)
                                   / nullif(sum(team_games.off_plays), 0)
        with synonyms ('offensive epa per play', 'epa per play')
        comment = 'Offensive EPA per scrimmage play, total EPA over total plays. The headline efficiency number; positive is good.',
    team_games.off_success_rate as sum(team_games.success_plays)
                                   / nullif(sum(team_games.off_plays), 0)
        with synonyms ('success rate')
        comment = 'Share of offensive scrimmage plays graded successful, successes over plays.',
    team_games.early_down_success_rate as sum(team_games.early_down_success_plays)
                                          / nullif(sum(team_games.early_down_plays), 0)
        comment = 'Offensive success rate on first and second down only.',
    team_games.pass_epa_per_dropback as sum(team_games.pass_epa)
                                        / nullif(sum(team_games.dropbacks), 0)
        comment = 'EPA per dropback on this offense''s pass plays.',
    team_games.rush_epa_per_carry as sum(team_games.rush_epa)
                                     / nullif(sum(team_games.epa_carries), 0)
        comment = 'EPA per carry on this offense''s rush plays, over nflverse scrimmage carries (epa_carries), not the box score''s rushing_attempts.',
    team_games.explosive_play_rate as sum(team_games.explosive_plays)
                                      / nullif(sum(team_games.off_plays), 0)
        with synonyms ('explosive rate')
        comment = 'Share of offensive plays that were explosive: 20+ yard passes or 10+ yard rushes.',
    team_games.offense_pass_rate as sum(team_games.dropbacks)
                                    / nullif(sum(team_games.off_plays), 0)
        comment = 'Share of this offense''s scrimmage plays that were dropbacks.',
    team_games.proe as sum(team_games.pass_over_expected_sum)
                       / nullif(sum(team_games.xpass_plays), 0)
        with synonyms ('pass rate over expected')
        comment = 'Pass rate over expected: actual minus model-expected pass probability, averaged over plays with an xpass value. Positive means the offense throws more than situations predict.',

    -- defensive efficiency (EPA allowed). Lower is better on all of these.
    team_defense.def_epa_per_play_allowed as sum(team_defense.def_epa)
                                             / nullif(sum(team_defense.def_plays), 0)
        with synonyms ('defensive epa per play', 'epa allowed per play')
        comment = 'EPA allowed per opponent scrimmage play. Negative means the defense took value away.',
    team_defense.success_rate_allowed as sum(team_defense.def_success_plays)
                                         / nullif(sum(team_defense.def_plays), 0)
        comment = 'Share of opponent plays graded successful against this defense.',
    team_defense.early_down_success_rate_allowed as sum(team_defense.def_early_down_success_plays)
                                                    / nullif(sum(team_defense.def_early_down_plays), 0)
        comment = 'Opponent success rate on first and second down against this defense.',
    team_defense.pass_epa_per_dropback_allowed as sum(team_defense.def_pass_epa)
                                                  / nullif(sum(team_defense.def_dropbacks_faced), 0)
        comment = 'EPA allowed per opponent dropback.',
    team_defense.rush_epa_per_carry_allowed as sum(team_defense.def_rush_epa)
                                               / nullif(sum(team_defense.def_carries_faced), 0)
        comment = 'EPA allowed per opponent carry.',
    team_defense.explosive_rate_allowed as sum(team_defense.def_explosive_plays)
                                           / nullif(sum(team_defense.def_plays), 0)
        comment = 'Share of opponent plays that were explosive against this defense.',
    team_defense.proe_faced as sum(team_defense.def_pass_over_expected_sum)
                               / nullif(sum(team_defense.def_xpass_plays), 0)
        comment = 'Pass rate over expected that opponents showed against this defense. High means opponents threw more than their situations predict.',

    -- defensive production and volume
    team_defense.total_takeaways as sum(team_defense.takeaways)
        comment = 'Takeaways forced: opponents'' turnovers against this defense.',
    team_defense.total_sacks_recorded as sum(team_defense.sacks_recorded)
        with synonyms ('defensive sacks', 'sacks by the defense')
        comment = 'Sacks credited to this defense''s players. Fractional totals are real (half-sacks). The mirror of total_sacks_allowed on the offense side.',
    team_defense.dropbacks_faced_per_game as avg(team_defense.def_dropbacks_faced)
        comment = 'Average opponent dropbacks faced per game: IDP opportunity volume, how much pass-rush and coverage work a defense gets.',
    team_defense.third_down_pct_allowed as sum(team_defense.opp_third_down_conversions)
                                           / nullif(sum(team_defense.opp_third_down_attempts), 0)
        comment = 'Opponent third down conversion rate against this defense, total conversions over total attempts.',
    team_defense.red_zone_pct_allowed as sum(team_defense.opp_red_zone_scores)
                                         / nullif(sum(team_defense.opp_red_zone_attempts), 0)
        comment = 'Share of opponent red zone trips that produced a score against this defense.'
)

comment = 'NFL team performance at team-by-game grain, 2023 to 2025 seasons, seen from both sides of the ball. Each row is one team in one game with its result, full box score, the allowed side (yards and conversions surrendered, takeaways, sacks recorded) and nflverse EPA efficiency for offense and defense, so a single game appears twice. Use this for team records, scoring, offensive and defensive efficiency (EPA per play, success rate, explosive rate, PROE), home and away splits, and opponent analysis. Does NOT contain individual player statistics or play-by-play detail.'

ai_sql_generation 'DEFAULT TO REGULAR SEASON: unless the user explicitly says preseason, postseason, playoffs, or all games, always filter season_type = ''Regular Season''. Preseason results are not meaningful and including them corrupts records and averages.
DEFAULT SEASON: if no season is given, use the most recent season present in the data. Determine that from the data rather than assuming a year.
RECORDS: express a team record as wins-losses, and append ties only when ties is greater than zero (for example 15-2, or 9-7-1). A tie counts as half a win in win_pct.
RATES: always compute conversion and efficiency rates as a sum over a sum of the additive counts, never by averaging any per-game rate column. This applies to the EPA metrics too: use the counts and EPA sums (off_plays, success_plays, def_plays and so on), never a per-game percentage. Round percentages to one decimal place and present them as percentages.
YARDS AND POINTS: report as whole numbers.
EPA COVERAGE: every EPA, success, explosive and PROE column is NULL on preseason rows (has_nflverse = false) because nflverse publishes no preseason play-by-play. Never treat those NULLs as zero, and exclude preseason from any efficiency ranking.
SACKS: two sack readings exist. total_sacks_allowed on the offense side counts sacks this team''s quarterback took; total_sacks_recorded on the defense side counts sacks credited to this team''s defenders, in fractional half-sacks. Resolve which direction the user means before answering.
GRAIN WARNING: the grain is team x game, so counting rows counts team-games, not games. To count distinct games use count(distinct game_key).
HOME AND AWAY: use is_home for splits rather than comparing team to opponent.
BOX SCORE GAPS: four team-game rows have has_box_score = false and NULL box score measures. Results are still valid for those rows, so do not filter them out of record or scoring questions.'

ai_question_categorization 'Answer questions about team results, records, scoring, offensive and defensive efficiency (EPA per play, success rate, explosive plays, PROE), yards and conversions allowed, takeaways, sacks on either side of the ball, penalties, turnovers, time of possession, and home or away and opponent splits.
If the question is about an INDIVIDUAL PLAYER''s statistics (passing, rushing, receiving, tackles, sacks, kicking), mark it out of scope and tell the user that player statistics live in the player semantic views, not this one.
If the question asks for situational splits by down, distance, field zone or game script, mark it out of scope and route it to NFLTeamSituationAnalytics.
If the question names a season that is not present in the data, say which seasons are actually available rather than assuming a fixed range.
If a team is named ambiguously (for example just a city that has moved, or a nickname shared across leagues), ask the user to confirm which team they mean.'

ai_verified_queries (
    team_epa_profile as (
        question 'What was each team''s offensive and defensive efficiency profile in the 2025 regular season?'
        verified_at 1787788800
        onboarding_question true
        sql 'SELECT team_abbreviation, off_epa_per_play, off_success_rate,
                    def_epa_per_play_allowed, success_rate_allowed
             FROM SEMANTIC_VIEW({{ this }}
               METRICS team_games.off_epa_per_play, team_games.off_success_rate,
                       team_defense.def_epa_per_play_allowed,
                       team_defense.success_rate_allowed
               DIMENSIONS teams.team_abbreviation, weeks.season,
                          weeks.season_type)
             WHERE season = 2025 AND season_type = ''Regular Season''
             ORDER BY off_epa_per_play DESC'
    ),
    team_last5_form as (
        question 'How have the Detroit Lions looked over their last five games?'
        verified_at 1787788800
        sql 'SELECT game_date, off_epa_per_play, off_success_rate,
                    total_points_scored
             FROM SEMANTIC_VIEW({{ this }}
               METRICS team_games.off_epa_per_play,
                       team_games.off_success_rate,
                       team_games.total_points_scored
               DIMENSIONS games.game_date, teams.team_full_name)
             WHERE team_full_name = ''Detroit Lions''
             ORDER BY game_date DESC
             LIMIT 5'
    ),
    idp_opportunity_defenses as (
        question 'Which defenses face the most dropbacks per game?'
        verified_at 1787788800
        sql 'SELECT team_abbreviation, dropbacks_faced_per_game, def_epa_per_play_allowed
             FROM SEMANTIC_VIEW({{ this }}
               METRICS team_defense.dropbacks_faced_per_game,
                       team_defense.def_epa_per_play_allowed
               DIMENSIONS teams.team_abbreviation, weeks.season,
                          weeks.season_type)
             WHERE season = 2025 AND season_type = ''Regular Season''
             ORDER BY dropbacks_faced_per_game DESC'
    )
)
