{{ config(materialized='semantic_view') }}

/*
    sv_wnba_player_performance -- the individual box score, one row per player
    per game.

    Grain: player x game (5,751 rows over 237 games and 231 players), 2026
    season.

    IT IS "PERFORMANCE" AND NOT "OFFENSE", AND THAT IS A DELIBERATE DEVIATION
    FROM THE NFL SIDE, where the player phase is split into sv_nfl_player_offense
    and sv_nfl_player_defense. A basketball box score has no phases: every
    player who takes the floor can record every measure in it, the whole line
    is sixteen columns, and splitting it would invent a distinction the sport
    does not have. Steals, blocks and defensive rebounds therefore live HERE.
    There is no WNBA defence view and there should not be one.

    DNP ROWS ARE INCLUDED, WITH EVERY MEASURE NULL. 1,076 of the 5,751 rows are
    players who dressed and did not play. This is the single most important
    thing to get right in this view, and it is why the per-game metrics below
    divide by sum(game_played_count) and never by count(*):

      * count(player_game_key) is games DRESSED, 5,751 of them.
      * sum(game_played_count) is games PLAYED, 4,653 of them.
      * dividing points by the first understates every scoring average by
        roughly a fifth, and does it silently.

    SQL''s own AVG would also exclude DNPs, because the measures are NULL rather
    than 0 on those rows. The explicit sum-over-sum form is used anyway so the
    denominator is visible in the metric definition rather than implied by a
    NULL, and so the same denominator is used for every rate.

    NO STORED PERCENTAGE COLUMNS. The player source carries makes and attempts
    only, on purpose: a per-game shooting percentage cannot be averaged across
    games without reweighting. Every shooting rate here is computed sum over
    sum and is a 0-1 fraction, matching the convention in the other three WNBA
    views.

    TEAM IS PER GAME AND THAT MAKES IT AUTHORITATIVE. team_key on the fact is
    the team the player appeared for in THAT game. dim_wnba_player also carries a
    current_team, which is a roster snapshot; it is not exposed here because
    the per-game affiliation is strictly better at this grain.

    minutes_played is minutes IN THAT GAME. The advanced view''s minutes columns
    are a per-game average and a season total, which are different things.
*/

tables (
    player_games as {{ ref('fact_wnba_player_game') }}
        primary key (player_game_key)
        with synonyms ('box score', 'player games', 'game log', 'player stats')
        comment = 'One row per player per game: the full box score line plus minutes and plus-minus. Includes rows for players who dressed and did not play, on which every measure is NULL. 2026 season only.',

    players as {{ ref('dim_wnba_player') }}
        primary key (player_key)
        comment = 'Player identity and position. 860 players, of whom 231 appear in a box score. Carries a current team, which is deliberately not exposed here because the per-game team on player_games is historically accurate and this one is not.',

    teams as {{ ref('dim_wnba_team') }}
        primary key (team_key)
        comment = 'The team the player appeared for in a given game.',

    games as {{ ref('dim_wnba_game') }}
        primary key (game_key)
        comment = 'Game context: date, season and season type.'
)

relationships (
    pg_to_player as player_games (player_key) references players (player_key),
    pg_to_team as player_games (team_key) references teams (team_key),
    pg_to_game as player_games (game_key) references games (game_key)
)

facts (
    -- playing time. game_played_count is the denominator for every rate below.
    player_games.game_played_count as game_played_count
        with synonyms ('games played indicator', 'appearances')
        comment = 'Additive 1/0 indicator: 1 when the player took the floor, 0 on a DNP. SUM this to get games played. This is the only correct denominator for a per-game average in this view.',
    player_games.minutes_played as minutes_played
        with synonyms ('minutes', 'floor time')
        comment = 'Minutes played in this game, 0 to 53. NULL on the 7 DNP rows where the source said only that the player did not play. Minutes in THIS game, not a season average.',

    -- scoring
    player_games.points as points
        comment = 'Points scored in this game. NULL on a DNP row, never 0.',

    -- shooting. Makes and attempts only; rates are metrics.
    player_games.field_goals_made as field_goals_made
        comment = 'Field goals made, including three pointers.',
    player_games.field_goals_attempted as field_goals_attempted
        comment = 'Field goals attempted, including three pointers.',
    player_games.three_pointers_made as three_pointers_made
        comment = 'Three pointers made. A subset of field_goals_made.',
    player_games.three_pointers_attempted as three_pointers_attempted
        comment = 'Three pointers attempted. A subset of field_goals_attempted.',
    player_games.free_throws_made as free_throws_made comment = 'Free throws made.',
    player_games.free_throws_attempted as free_throws_attempted comment = 'Free throws attempted.',

    -- rebounding
    player_games.offensive_rebounds as offensive_rebounds comment = 'Rebounds at the offensive end.',
    player_games.defensive_rebounds as defensive_rebounds comment = 'Rebounds at the defensive end.',
    player_games.rebounds as rebounds
        comment = 'Total rebounds. The source''s own total, not recomputed from the two splits.',

    -- playmaking and defence
    player_games.assists as assists comment = 'Assists recorded.',
    player_games.steals as steals comment = 'Steals recorded. A defensive measure, and it lives here because a basketball box score is one block.',
    player_games.blocks as blocks comment = 'Shots blocked.',
    player_games.turnovers as turnovers comment = 'Turnovers committed by this player.',
    player_games.personal_fouls as personal_fouls comment = 'Personal fouls committed.',

    -- differential
    player_games.plus_minus as plus_minus
        with synonyms ('plus minus', 'point differential on court')
        comment = 'Team scoring margin while this player was on the floor. A differential, not a count: it is additive across one player''s games but averaging it across players answers a different question than it looks like it does.'
)

dimensions (
    -- who
    players.full_name as full_name
        with synonyms ('player', 'player name', 'athlete')
        comment = 'Player full name. High cardinality; a Cortex Search service would improve fuzzy name matching.'
        sample_values ('A''ja Wilson', 'Kelsey Mitchell', 'Breanna Stewart', 'Napheesa Collier', 'Caitlin Clark'),
    players.position_name as position_name
        with synonyms ('position', 'listed position')
        comment = 'Clean position label derived from the single-vocabulary position abbreviation. The raw source column mixes two vocabularies, spelling the same role both Guard and G, so it is not used. Unknown for the 130 players with no position on file.'
        sample_values ('Guard', 'Forward', 'Center', 'Unknown') is_enum,
    players.jersey_number as jersey_number
        comment = 'Shirt number. NULL for the 329 players with none on file.',

    -- for whom, in this game
    teams.team_abbreviation as team_abbreviation
        with synonyms ('team', 'club')
        comment = 'Short code of the team the player appeared for IN THIS GAME. This is the historically accurate affiliation and should be preferred over any roster listing.'
        sample_values ('LV', 'NY', 'MIN', 'PHX', 'SEA', 'IND', 'ATL'),
    teams.team_full_name as team_full_name
        comment = 'Full name of the team the player appeared for in this game.'
        sample_values ('Las Vegas Aces', 'New York Liberty', 'Minnesota Lynx', 'Indiana Fever'),

    -- when
    games.season as season
        comment = 'WNBA season. This view holds 2026 only. There is no career or multi-season player data anywhere in this warehouse.',
    games.season_type_name as season_type_name
        with synonyms ('phase', 'part of season', 'regular or all-star')
        comment = 'Four-way classification: Regular Season, All-Star, Postseason, Preseason. Only Regular Season (5,729 rows) and All-Star (22 rows) are present today. Almost all questions mean Regular Season.'
        sample_values ('Regular Season', 'All-Star'),
    games.game_date as game_date
        comment = 'Calendar date the game was played, from 2026-05-08 to 2026-08-08.',

    -- did she play
    player_games.is_dnp as is_dnp
        with synonyms ('did not play', 'dnp', 'inactive')
        comment = 'True on the 1,076 rows where the player dressed and did not take the floor. Every measure on those rows is NULL rather than 0. Per-game averages already exclude them; filter on it only when the question is explicitly about availability.'
)

metrics (
    -- the two denominators, kept distinct on purpose
    player_games.games_played as sum(player_games.game_played_count)
        with synonyms ('games', 'appearances', 'games she played')
        comment = 'Games in which the player took the floor. This is the denominator for every per-game metric below. It is a SUM and not a COUNT because DNP rows exist and a COUNT would include them.',
    player_games.games_dressed as count(player_games.player_game_key)
        with synonyms ('games available', 'games on the roster')
        comment = 'Games in which the player appeared on the game report, played or not. Larger than games_played by the number of DNPs. Never use this as a per-game denominator.',
    player_games.games_missed as count(player_games.player_game_key)
                                 - sum(player_games.game_played_count)
        with synonyms ('dnps', 'games not played')
        comment = 'Games dressed minus games played: the number of DNPs in the selection.',

    -- scoring and production totals
    player_games.total_points as sum(player_games.points)
        with synonyms ('points', 'total scoring')
        comment = 'Total points scored.',
    player_games.total_rebounds as sum(player_games.rebounds)
        with synonyms ('rebounds', 'boards')
        comment = 'Total rebounds.',
    player_games.total_assists as sum(player_games.assists)
        with synonyms ('assists', 'dimes')
        comment = 'Total assists.',
    player_games.total_steals as sum(player_games.steals)
        with synonyms ('steals')
        comment = 'Total steals.',
    player_games.total_blocks as sum(player_games.blocks)
        with synonyms ('blocks', 'rejections')
        comment = 'Total blocks.',
    player_games.total_turnovers as sum(player_games.turnovers)
        with synonyms ('turnovers', 'giveaways')
        comment = 'Total turnovers committed.',
    player_games.total_minutes as sum(player_games.minutes_played)
        comment = 'Total minutes played across the selection.',
    player_games.total_plus_minus as sum(player_games.plus_minus)
        with synonyms ('plus minus total', 'net on court')
        comment = 'Team scoring margin accumulated while this player was on the floor.',

    -- per game. Denominator is games PLAYED, never row count.
    player_games.points_per_game as sum(player_games.points)
                                    / nullif(sum(player_games.game_played_count), 0)
        with synonyms ('ppg', 'scoring average', 'points per game')
        comment = 'Points divided by games PLAYED. Dividing by the row count instead would include the 1,076 DNP rows and understate every scoring average by roughly a fifth.',
    player_games.rebounds_per_game as sum(player_games.rebounds)
                                      / nullif(sum(player_games.game_played_count), 0)
        with synonyms ('rpg', 'rebounding average')
        comment = 'Rebounds divided by games PLAYED, for the same reason as points_per_game.',
    player_games.assists_per_game as sum(player_games.assists)
                                     / nullif(sum(player_games.game_played_count), 0)
        with synonyms ('apg', 'assist average')
        comment = 'Assists divided by games PLAYED.',
    player_games.steals_per_game as sum(player_games.steals)
                                    / nullif(sum(player_games.game_played_count), 0)
        with synonyms ('spg')
        comment = 'Steals divided by games PLAYED.',
    player_games.blocks_per_game as sum(player_games.blocks)
                                    / nullif(sum(player_games.game_played_count), 0)
        with synonyms ('bpg')
        comment = 'Blocks divided by games PLAYED.',
    player_games.turnovers_per_game as sum(player_games.turnovers)
                                       / nullif(sum(player_games.game_played_count), 0)
        comment = 'Turnovers divided by games PLAYED.',
    player_games.minutes_per_game as sum(player_games.minutes_played)
                                     / nullif(sum(player_games.game_played_count), 0)
        with synonyms ('mpg', 'minutes average', 'playing time')
        comment = 'Minutes divided by games PLAYED. A DNP contributes 0 to the numerator and 0 to the denominator, so it does not drag the average down.',

    -- shooting efficiency. Sum over sum, never an average of per-game rates.
    player_games.field_goal_pct as sum(player_games.field_goals_made)
                                   / nullif(sum(player_games.field_goals_attempted), 0)
        with synonyms ('fg%', 'field goal percentage', 'shooting percentage')
        comment = 'Field goal percentage, total makes over total attempts. A 0-1 fraction; multiply by 100 to display.',
    player_games.three_point_pct as sum(player_games.three_pointers_made)
                                    / nullif(sum(player_games.three_pointers_attempted), 0)
        with synonyms ('3p%', 'three point percentage', 'from deep')
        comment = 'Three point percentage, total makes over total attempts. A 0-1 fraction.',
    player_games.free_throw_pct as sum(player_games.free_throws_made)
                                   / nullif(sum(player_games.free_throws_attempted), 0)
        with synonyms ('ft%', 'free throw percentage')
        comment = 'Free throw percentage, total makes over total attempts. A 0-1 fraction.',
    player_games.effective_field_goal_pct as (sum(player_games.field_goals_made)
                                              + 0.5 * sum(player_games.three_pointers_made))
                                             / nullif(sum(player_games.field_goals_attempted), 0)
        with synonyms ('efg', 'effective field goal percentage')
        comment = 'Effective field goal percentage, crediting a three pointer as 1.5 makes. A 0-1 fraction. For true shooting, which also charges free throw attempts, use the player advanced view.'
)

comment = 'Individual WNBA box score production at player-by-game grain, 2026 season. 5,751 rows over 237 games and 231 players, covering scoring, shooting, rebounding, assists, steals, blocks, turnovers, fouls, minutes and plus-minus in one block, because a basketball box score has no offence and defence split. Rows for players who dressed and did not play are included with NULL measures. Does NOT contain seasons before 2026 or any career totals, advanced efficiency metrics such as PIE, usage rate, true shooting or on-off ratings, shot location or zone shooting data, play-by-play detail, or team-level results and standings.'

ai_sql_generation 'DEFAULT TO REGULAR SEASON: unless the user explicitly says All-Star or all games, always filter season_type_name = ''Regular Season''. This excludes the 22 player-games from the All-Star exhibition and any preseason exhibition, whose production is not competitive.
DNP RULE, THE MOST IMPORTANT RULE IN THIS VIEW: 1,076 of the 5,751 rows are players who dressed and did not play. They carry 0 minutes and NULL for every measure. A per-game average must divide by games PLAYED, which is sum(game_played_count), and NEVER by count(*) or count(player_game_key), which is games DRESSED. Every per-game metric here already does this; if you write a per-game ratio by hand, use sum(game_played_count) as the denominator. Do not filter is_dnp = false to fix this, because it is already handled and filtering changes nothing except making the query harder to read.
TEAM AFFILIATION: the team on each row is the team the player actually appeared for in THAT game, which makes it authoritative. A player''s listed team elsewhere in this warehouse is a current-roster snapshot and can attribute a whole season to whichever club she finished with. Prefer the team here whenever the question is at game grain.
SEASON COVERAGE: 2026 only. There are no career statistics, no earlier seasons and no rookie-versus-veteran comparison across years. If the user asks for a career total or a multi-season trend, say the source covers the 2026 season only rather than returning a partial answer.
COMMISSIONER''S CUP: Commissioner''s Cup group-stage games are indistinguishable from ordinary regular-season games in this source. There is no flag for them, so they are always included and cannot be isolated.
RATES: compute every shooting rate as a sum over a sum, never as an average of per-game percentages. Every rate metric here is already written that way.
PERCENTAGE SCALE: every rate metric in this view returns a 0 to 1 fraction. Multiply by 100 and round to one decimal place when presenting, for example 0.462 shown as 46.2%. Per-game averages take one decimal place; counting totals are whole numbers.
LEADERBOARD FLOOR: when ranking players by a per-game average or a shooting rate, require a minimum sample or a bench player with three good minutes tops the list. Use at least 10 games played, and for a shooting rate at least 100 field goal attempts. State the floor you applied in the answer.
PLUS MINUS: total_plus_minus is a team margin accumulated while a player was on the floor. It is heavily dependent on team quality, so present it with that caveat rather than as an individual measure.
GRAIN: one row per player per game. To count games use count(distinct game_key); to count players use count(distinct player_key).
NO PERCENTAGES ARE STORED: the underlying fact carries makes and attempts only, so there is no per-game shooting percentage column to average. This is deliberate.'

ai_question_categorization 'Answer questions about individual WNBA box score production in 2026: points, rebounds, assists, steals, blocks, turnovers, fouls, shooting makes and attempts, minutes and plus-minus, at game or season-to-date grain, including game logs, leaderboards and team-mate comparisons.
If the question asks for EFFICIENCY, USAGE or ADVANCED metrics such as PIE, usage rate, true shooting percentage, offensive or defensive rating, net rating, pace, assist percentage, rebound percentage, or a share of the team''s output, mark it out of scope and route it to WNBAPlayerAdvancedAnalytics.
If the question is about a TEAM result, record, or team-level box score in the current season, mark it out of scope and route it to WNBATeamPerformanceAnalytics.
If the question is about FRANCHISE HISTORY, standings, playoff seeding or any season before 2026, mark it out of scope and route it to WNBATeamHistoryAnalytics, which is the only multi-season view in this set.
If the question asks for CAREER statistics, a multi-season player trend, or a comparison of a player to her own earlier seasons, explain that every player-level source here covers the 2026 season only.
If the question asks for SHOT LOCATION or distance-based shooting (shots in the paint, by zone, from five feet), explain that zone shooting data exists in the warehouse but is not exposed in any semantic view, so it cannot be answered.
If the question asks about INJURIES, availability reasons, or why a player did not play, explain that this view records only that she did not play and carries no reason.
If a player name is ambiguous or matches more than one player, list the candidates and ask which one they mean.
If the question filters on POSITION, note that 130 players carry the Unknown position because none is on file, and say whether they were excluded.'
