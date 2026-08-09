{{ config(materialized='semantic_view') }}

/*
    sv_nfl_player_defense -- individual tackling, pass rush and coverage.

    Grain: player x game (~44,600 rows), the largest of the player phase views.

    Two things worth knowing:
      * defensive_sacks is a FLOAT, not an integer. A shared sack counts as 0.5,
        and 1,032 rows carry a half value. Never round it to an integer.
      * sacks here are sacks RECORDED BY this defender. Sacks allowed by an
        offense are in sv_nfl_team_performance and are a different concept.

    Defensive statistics in this source are limited to the traditional box score.
    There is no snap count, coverage grade, pressure rate or missed tackle data,
    so questions about those cannot be answered.
*/

tables (
    player_games as {{ ref('fact_player_game_defense') }}
        primary key (player_game_key)
        comment = 'One row per player per game with defensive production. Grain is player x game. Includes preseason, regular season and postseason.',

    players as {{ ref('dim_player') }}
        primary key (player_key)
        comment = 'Player biographical attributes. Has no team column by design -- per-game team comes from player_games.',

    teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'The team the player appeared for in a given game.',

    games as {{ ref('dim_game') }}
        primary key (game_key)
        comment = 'Game context: date, venue and season type.',

    weeks as {{ ref('dim_season_week') }}
        primary key (season_week_key)
        comment = 'The NFL calendar. Week 1 exists in both preseason and regular season, so season_type is part of this key.'
)

relationships (
    pg_to_player as player_games (player_key) references players (player_key),
    pg_to_team as player_games (team_key) references teams (team_key),
    pg_to_game as player_games (game_key) references games (game_key),
    pg_to_week as player_games (season_week_key) references weeks (season_week_key)
)

facts (
    -- tackling
    player_games.tackles as total_tackles comment = 'Total tackles: solo plus assisted.',
    player_games.solo as solo_tackles comment = 'Unassisted tackles.',
    player_games.assisted as assisted_tackles comment = 'Assisted tackles, derived as total minus solo.',
    player_games.tfl as tackles_for_loss comment = 'Tackles made behind the line of scrimmage.',

    -- pass rush
    player_games.sacks as defensive_sacks comment = 'Sacks recorded. FLOAT: a shared sack is 0.5.',
    player_games.hits as qb_hits comment = 'Quarterback hits that were not sacks.',

    -- coverage
    player_games.pass_defended as passes_defended comment = 'Passes broken up or deflected.',
    player_games.ints as defensive_interceptions comment = 'Interceptions caught.',
    player_games.int_yards as interception_yards comment = 'Yards returned after an interception.',
    player_games.int_tds as interception_touchdowns comment = 'Touchdowns scored on an interception return.',

    -- takeaways
    player_games.fum_recovered as fumbles_recovered comment = 'Opponent fumbles recovered.',
    player_games.fum_tds as fumbles_touchdowns comment = 'Touchdowns scored on a fumble recovery.',
    player_games.total_takeaways as takeaways comment = 'Interceptions plus fumble recoveries.',
    player_games.def_tds as defensive_touchdowns comment = 'Interception plus fumble return touchdowns.'
)

dimensions (
    -- who
    players.player_name as full_name
        comment = 'Player full name. High cardinality -- a Cortex Search service would improve fuzzy name matching.'
        sample_values ('Micah Parsons', 'Myles Garrett', 'Fred Warner', 'T.J. Watt'),
    players.position as position_name
        comment = 'Clean position label derived from the position abbreviation. Unknown for players with no position on file.'
        sample_values ('Linebacker', 'Defensive End', 'Cornerback', 'Safety', 'Defensive Tackle'),
    players.position_group as position_group
        comment = 'Coarse unit grouping. Defensive groups are the ones that appear in this view.'
        sample_values ('Defense - Line', 'Defense - Linebacker', 'Defense - Secondary', 'Unknown'),
    players.college as college
        comment = 'College attended. Null for many players.',
    players.is_rookie as is_rookie
        comment = 'True in a player''s first season.',

    -- for whom
    teams.team_abbreviation as team_abbreviation
        comment = 'Three-letter code of the team the player appeared for in this game.'
        sample_values ('KC', 'PHI', 'DET', 'BUF', 'PIT'),
    teams.team_full_name as team_full_name
        comment = 'Full name of the team the player appeared for in this game.'
        sample_values ('Kansas City Chiefs', 'Pittsburgh Steelers', 'San Francisco 49ers'),
    teams.conference as conference
        comment = 'AFC or NFC.'
        sample_values ('AFC', 'NFC') is_enum,

    -- when
    weeks.season as season
        comment = 'NFL season. Currently covers 2023 to 2025; new seasons are added as they load. A season starting in year N runs through February of N+1.',
    weeks.week as week
        comment = 'Week within the season phase. Regular season is weeks 1 to 18; numbering restarts for preseason and postseason.',
    weeks.season_type as season_type_name
        with synonyms ('regular or playoff')
        comment = 'Preseason, Regular Season or Postseason. Almost all questions mean Regular Season.'
        sample_values ('Preseason', 'Regular Season', 'Postseason') is_enum,
    games.game_date as game_date
        comment = 'Calendar date the game was played.'
)

metrics (
    player_games.games_played as count(player_games.player_game_key)
        comment = 'Games in which the player recorded defensive production.',

    -- tackling
    player_games.total_tackles_made as sum(player_games.tackles)
        with synonyms ('tackles')
        comment = 'Total tackles, solo plus assisted.',
    player_games.total_solo_tackles as sum(player_games.solo)
        comment = 'Total unassisted tackles.',
    player_games.total_assisted_tackles as sum(player_games.assisted)
        comment = 'Total assisted tackles.',
    player_games.total_tackles_for_loss as sum(player_games.tfl)
        with synonyms ('tfl', 'tackles for loss', 'stops behind the line')
        comment = 'Total tackles behind the line of scrimmage.',
    player_games.tackles_per_game as avg(player_games.tackles)
        comment = 'Average tackles per game played.',

    -- pass rush
    player_games.total_sacks as sum(player_games.sacks)
        with synonyms ('sacks', 'sacks recorded')
        comment = 'Total sacks recorded BY this defender. Can be fractional -- a shared sack is 0.5. Do not confuse with sacks allowed by an offense.',
    player_games.total_qb_hits as sum(player_games.hits)
        with synonyms ('quarterback hits')
        comment = 'Total quarterback hits that were not sacks.',
    player_games.pressures as sum(player_games.sacks) + sum(player_games.hits)
        with synonyms ('pressures')
        comment = 'Sacks plus quarterback hits. The closest available proxy for pressure -- this source has no true pressure or hurry count.',

    -- coverage
    player_games.total_passes_defended as sum(player_games.pass_defended)
        with synonyms ('pass breakups', 'passes defended')
        comment = 'Total passes broken up or deflected.',
    player_games.total_interceptions as sum(player_games.ints)
        with synonyms ('interceptions', 'picks', 'interceptions caught')
        comment = 'Total interceptions caught. This is a defensive takeaway, not interceptions thrown by a quarterback.',
    player_games.total_interception_yards as sum(player_games.int_yards)
        comment = 'Total yards returned after interceptions.',
    player_games.total_interception_tds as sum(player_games.int_tds)
        comment = 'Total touchdowns on interception returns.',

    -- takeaways and scoring
    player_games.total_fumbles_recovered as sum(player_games.fum_recovered)
        with synonyms ('fumble recoveries')
        comment = 'Total opponent fumbles recovered.',
    player_games.takeaways_total as sum(player_games.total_takeaways)
        with synonyms ('takeaways')
        comment = 'Interceptions plus fumble recoveries. The standard combined ball-production measure.',
    player_games.defensive_scores as sum(player_games.def_tds)
        with synonyms ('defensive touchdowns', 'scoop and score')
        comment = 'Touchdowns scored on interception or fumble returns.'
)

comment = 'Individual NFL defensive production at player-by-game grain, 2023 to 2025 seasons. Covers tackling, pass rush, coverage and takeaways for every player who recorded defensive production. Sacks here are sacks RECORDED BY the defender and are fractional. Does NOT contain offensive statistics, kicking or returns, Next Gen tracking metrics, snap counts, pressure rates, or team-level results.'

ai_sql_generation 'DEFAULT TO REGULAR SEASON: unless the user explicitly says preseason, postseason, playoffs, or career/all games, filter season_type = ''Regular Season''.
DEFAULT SEASON: if no season is given, use the most recent season present in the data. Determine that from the data rather than assuming a year.
SACKS ARE FRACTIONAL: total_sacks is a FLOAT because a shared sack counts as 0.5. Never cast it to an integer and never round it to a whole number. Present it to one decimal place, for example 17.5.
SACKS DIRECTION: total_sacks counts sacks this defender recorded. If the user asks how many sacks a team ALLOWED, that is an offensive measure in the team performance view, not this one.
INTERCEPTIONS DIRECTION: total_interceptions here means interceptions CAUGHT by a defender. Interceptions thrown by a quarterback are in the player offense view.
IDENTIFY BY ACTIVITY, NOT POSITION: the listed position is Unknown for many players who appear in box scores, so prefer filtering on the statistic itself rather than on position. Use position_group only when the user explicitly asks by unit.
RATES: compute as a sum over a sum, never as an average of per-game rates. When ranking by a per-game average require at least 8 games played in the season and say so.
NO PRESSURE DATA: the pressures metric is sacks plus quarterback hits, which is a proxy. If the user asks for true pressure rate, hurries, or missed tackles, say the source does not carry them.
GRAIN: one row per player per game. To count games use count(player_game_key); to count distinct players use count(distinct player_key).'

ai_question_categorization 'Answer questions about individual defensive production: tackles, tackles for loss, sacks, quarterback hits, passes defended, interceptions, fumble recoveries, takeaways and defensive touchdowns.
If the question is about OFFENSIVE statistics (passing, rushing, receiving), mark it out of scope and tell the user those live in the player offense view.
If the question is about KICKING, PUNTING or RETURNS, mark it out of scope and point to the special teams data.
If the question asks for NEXT GEN or tracking metrics, mark it out of scope and point to the player advanced view.
If the question is about a TEAM result, record or team-level defense rather than an individual, mark it out of scope and point to the team performance view.
If the question asks about SNAP COUNTS, pressure rate, hurries, coverage grades, missed tackles or targets allowed, explain that this source carries only traditional box score defensive statistics.
If the question is ambiguous about sack DIRECTION (recorded versus allowed) or interception DIRECTION (caught versus thrown), ask the user to clarify before answering.
If the question names a season that is not present in the data, say which seasons are actually available rather than assuming a fixed range.
If a player name is ambiguous or matches multiple players, list the candidates and ask which one they mean.'
