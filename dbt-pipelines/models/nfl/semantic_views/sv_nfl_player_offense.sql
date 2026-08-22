{{ config(materialized='semantic_view') }}

/*
    sv_nfl_player_offense -- individual passing, rushing and receiving.

    Grain: player x game (~23,200 rows). One row per player per game in which he
    recorded offensive involvement.

    Scope note: this is one of three player phase views. Defensive statistics are
    in sv_nfl_player_defense and Next Gen tracking metrics are in
    sv_nfl_player_advanced. A player who contributed in more than one phase
    appears in more than one view; the measure sets are disjoint so nothing is
    double counted, but the views cannot be joined to each other.

    team_key is the team the player appeared for in THIS game, which is the only
    historically accurate affiliation in the source. dim_player deliberately has
    no team column.
*/

tables (
    player_games as {{ ref('fact_player_game_offense') }}
        primary key (player_game_key)
        comment = 'One row per player per game with passing, rushing and receiving production. Grain is player x game. Includes preseason, regular season and postseason.',

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
    -- passing
    player_games.pass_attempts as passing_attempts comment = 'Pass attempts.',
    player_games.pass_completions as passing_completions comment = 'Completed passes.',
    player_games.pass_yards as passing_yards comment = 'Passing yards.',
    player_games.pass_tds as passing_touchdowns comment = 'Passing touchdowns.',
    player_games.pass_ints as passing_interceptions comment = 'Interceptions thrown.',
    player_games.sacked as times_sacked comment = 'Times this player was sacked.',
    player_games.sacked_yards as sack_yards_lost comment = 'Yards lost to sacks.',
    player_games.passer_rating as qb_rating comment = 'Traditional passer rating.',
    player_games.total_qbr as qbr comment = 'ESPN QBR, 0 to 100 scale.',

    -- rushing
    player_games.rush_attempts as rushing_attempts comment = 'Rushing attempts (carries).',
    player_games.rush_yards as rushing_yards comment = 'Rushing yards.',
    player_games.rush_tds as rushing_touchdowns comment = 'Rushing touchdowns.',
    player_games.longest_rush as long_rushing comment = 'Longest single rush, in yards.',

    -- receiving
    player_games.targets as receiving_targets comment = 'Times targeted by a pass.',
    player_games.catches as receptions comment = 'Passes caught.',
    player_games.rec_yards as receiving_yards comment = 'Receiving yards.',
    player_games.rec_tds as receiving_touchdowns comment = 'Receiving touchdowns.',
    player_games.longest_catch as long_reception comment = 'Longest single reception, in yards.',

    -- combined and ball security
    player_games.total_scrimmage_yards as scrimmage_yards comment = 'Rushing plus receiving yards. Zero, not null, for a player with neither.',
    player_games.total_scrimmage_tds as scrimmage_touchdowns comment = 'Rushing plus receiving touchdowns.',
    player_games.total_touches as touches comment = 'Carries plus receptions.',
    player_games.fumbles_committed as fumbles comment = 'Fumbles, whether or not lost.',
    player_games.fumbles_turned_over as fumbles_lost comment = 'Fumbles lost to the opponent.',

    -- fantasy
    player_games.two_pt_conversions as two_point_conversions comment = 'Two-point conversions rushed or caught, parsed from play-by-play. Zero when none.',
    player_games.fanduel_pts as fanduel_points comment = 'FanDuel fantasy points for this player-game under FanDuel NFL scoring (half PPR, -2 per fumble lost). Zero, not null, when nothing scored.',
    player_games.draftkings_pts as draftkings_points comment = 'DraftKings fantasy points for this player-game under DraftKings Classic scoring (full PPR, -1 per fumble lost). Zero, not null, when nothing scored.'
)

dimensions (
    -- who
    players.player_name as full_name
        comment = 'Player full name. High cardinality -- a Cortex Search service would improve fuzzy name matching.'
        sample_values ('Patrick Mahomes', 'Joe Burrow', 'Saquon Barkley', 'Ja''Marr Chase'),
    players.position as position_name
        comment = 'Clean position label derived from the position abbreviation. Unknown for players with no position on file.'
        sample_values ('Quarterback', 'Running Back', 'Wide Receiver', 'Tight End', 'Fullback'),
    players.position_group as position_group
        comment = 'Coarse unit grouping. Offensive skill positions are the ones that appear in this view.'
        sample_values ('Offense - Skill', 'Offense - Line', 'Special Teams', 'Unknown'),
    players.college as college
        comment = 'College attended. Null for many players.',
    players.is_rookie as is_rookie
        comment = 'True in a player''s first season.',

    -- for whom
    teams.team_abbreviation as team_abbreviation
        comment = 'Three-letter code of the team the player appeared for in this game.'
        sample_values ('KC', 'PHI', 'DET', 'BUF', 'CIN'),
    teams.team_full_name as team_full_name
        comment = 'Full name of the team the player appeared for in this game.'
        sample_values ('Kansas City Chiefs', 'Philadelphia Eagles', 'Detroit Lions'),
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
        comment = 'Calendar date the game was played.',

    -- phase participation
    player_games.has_passing as has_passing
        comment = 'True when this player attempted a pass in this game. Use to isolate quarterbacks by activity rather than by listed position.',
    player_games.has_rushing as has_rushing
        comment = 'True when this player recorded a carry in this game.',
    player_games.has_receiving as has_receiving
        comment = 'True when this player was targeted in this game.'
)

metrics (
    player_games.games_played as count(player_games.player_game_key)
        comment = 'Games in which the player recorded offensive involvement.',

    -- passing volume
    player_games.total_pass_attempts as sum(player_games.pass_attempts)
        comment = 'Total pass attempts.',
    player_games.total_pass_completions as sum(player_games.pass_completions)
        comment = 'Total completions.',
    player_games.total_pass_yards as sum(player_games.pass_yards)
        with synonyms ('passing yards')
        comment = 'Total passing yards.',
    player_games.total_pass_tds as sum(player_games.pass_tds)
        with synonyms ('passing touchdowns', 'td passes')
        comment = 'Total passing touchdowns.',
    player_games.total_interceptions as sum(player_games.pass_ints)
        with synonyms ('picks', 'interceptions thrown')
        comment = 'Total interceptions thrown.',
    player_games.total_times_sacked as sum(player_games.sacked)
        comment = 'Total times sacked.',

    -- passing efficiency, computed sum over sum
    player_games.completion_pct as sum(player_games.pass_completions)
                                   / nullif(sum(player_games.pass_attempts), 0)
        with synonyms ('completion percentage', 'completion rate')
        comment = 'Completions divided by attempts. Only meaningful with enough volume -- require at least 100 attempts in a season.',
    player_games.yards_per_attempt as sum(player_games.pass_yards)
                                      / nullif(sum(player_games.pass_attempts), 0)
        with synonyms ('yards per attempt', 'ypa')
        comment = 'Passing yards per attempt.',
    player_games.td_to_int_ratio as sum(player_games.pass_tds)
                                    / nullif(sum(player_games.pass_ints), 0)
        with synonyms ('td to int ratio', 'touchdown to interception ratio')
        comment = 'Passing touchdowns per interception. Null when the player threw no interceptions.',
    player_games.avg_passer_rating as avg(player_games.passer_rating)
        comment = 'Average traditional passer rating across games.',
    player_games.avg_qbr as avg(player_games.total_qbr)
        comment = 'Average ESPN QBR across games.',

    -- rushing
    player_games.total_rush_attempts as sum(player_games.rush_attempts)
        with synonyms ('carries')
        comment = 'Total rushing attempts.',
    player_games.total_rush_yards as sum(player_games.rush_yards)
        with synonyms ('rushing yards', 'ground yards')
        comment = 'Total rushing yards.',
    player_games.total_rush_tds as sum(player_games.rush_tds)
        comment = 'Total rushing touchdowns.',
    player_games.yards_per_carry as sum(player_games.rush_yards)
                                    / nullif(sum(player_games.rush_attempts), 0)
        with synonyms ('yards per carry', 'ypc', 'rushing average')
        comment = 'Rushing yards per attempt. Require at least 50 carries in a season for this to be meaningful.',
    player_games.longest_run as max(player_games.longest_rush)
        comment = 'Longest single rush.',

    -- receiving
    player_games.total_targets as sum(player_games.targets)
        comment = 'Total times targeted.',
    player_games.total_receptions as sum(player_games.catches)
        with synonyms ('catches')
        comment = 'Total receptions.',
    player_games.total_rec_yards as sum(player_games.rec_yards)
        with synonyms ('receiving yards')
        comment = 'Total receiving yards.',
    player_games.total_rec_tds as sum(player_games.rec_tds)
        comment = 'Total receiving touchdowns.',
    player_games.catch_rate as sum(player_games.catches)
                               / nullif(sum(player_games.targets), 0)
        with synonyms ('catch rate', 'catch percentage')
        comment = 'Receptions divided by targets.',
    player_games.yards_per_catch as sum(player_games.rec_yards)
                                    / nullif(sum(player_games.catches), 0)
        with synonyms ('yards per reception', 'ypr')
        comment = 'Receiving yards per reception.',
    player_games.longest_reception as max(player_games.longest_catch)
        comment = 'Longest single reception.',

    -- combined production
    player_games.total_scrimmage as sum(player_games.total_scrimmage_yards)
        with synonyms ('scrimmage yards', 'total yards from scrimmage')
        comment = 'Rushing plus receiving yards. The standard measure for comparing skill-position production.',
    player_games.total_scrimmage_touchdowns as sum(player_games.total_scrimmage_tds)
        comment = 'Rushing plus receiving touchdowns.',
    player_games.touches_total as sum(player_games.total_touches)
        with synonyms ('touches')
        comment = 'Carries plus receptions.',
    player_games.yards_per_touch as sum(player_games.total_scrimmage_yards)
                                    / nullif(sum(player_games.total_touches), 0)
        comment = 'Scrimmage yards per touch.',
    player_games.scrimmage_yards_per_game as avg(player_games.total_scrimmage_yards)
        comment = 'Average scrimmage yards per game played.',

    -- ball security
    player_games.total_fumbles as sum(player_games.fumbles_committed)
        comment = 'Total fumbles.',
    player_games.total_fumbles_lost as sum(player_games.fumbles_turned_over)
        comment = 'Total fumbles lost to the opponent.',

    -- fantasy
    player_games.total_fanduel_points as sum(player_games.fanduel_pts)
        with synonyms ('fantasy points', 'fanduel points', 'dfs points', 'fantasy score')
        comment = 'Total FanDuel fantasy points. FanDuel NFL scoring: half PPR, 4-point passing touchdowns, -1 per interception, -2 per fumble lost, 3-point bonuses at 100 rushing or receiving yards and 300 passing yards, 2 per two-point conversion. Offensive players only; kickers and defenses are not scored here.',
    player_games.fanduel_points_per_game as avg(player_games.fanduel_pts)
        with synonyms ('fantasy points per game', 'fanduel average')
        comment = 'Average FanDuel fantasy points per game played.',
    player_games.total_draftkings_points as sum(player_games.draftkings_pts)
        with synonyms ('draftkings points', 'dk points', 'draftkings score')
        comment = 'Total DraftKings fantasy points. DraftKings Classic scoring: full PPR (1 per reception), 4-point passing touchdowns, -1 per interception, -1 per fumble lost, 3-point bonuses at 100 rushing or receiving yards and 300 passing yards, 2 per two-point conversion. Offensive players only; kickers and defenses are not scored here.',
    player_games.draftkings_points_per_game as avg(player_games.draftkings_pts)
        with synonyms ('draftkings points per game', 'dk average')
        comment = 'Average DraftKings fantasy points per game played.'
)

comment = 'Individual NFL offensive production at player-by-game grain, 2023 to 2025 seasons. Covers passing, rushing and receiving for every player who recorded offensive involvement, plus FanDuel and DraftKings fantasy points per game. Use this for statistical leaders, per-game production, efficiency rates and fantasy scoring. Does NOT contain defensive statistics, kicking or returns, Next Gen tracking metrics, or team-level results.'

ai_sql_generation 'DEFAULT TO REGULAR SEASON: unless the user explicitly says preseason, postseason, playoffs, or career/all games, filter season_type = ''Regular Season''.
DEFAULT SEASON: if no season is given, use the most recent season present in the data. Determine that from the data rather than assuming a year.
VOLUME QUALIFIERS ARE MANDATORY FOR RATE STATS: rate metrics are meaningless at low volume. 303 players threw at least one pass in a season but only 139 reached 100 attempts, so an unqualified "best completion percentage" returns a running back who completed a single trick-play pass. When ranking by completion_pct, yards_per_attempt or td_to_int_ratio, require at least 100 pass attempts in the season. When ranking by yards_per_carry require at least 50 carries. When ranking by catch_rate or yards_per_catch require at least 30 targets. State the qualifier you applied in the answer.
IDENTIFY BY ACTIVITY, NOT POSITION: to find quarterbacks use has_passing, running backs has_rushing, receivers has_receiving. The listed position is Unknown for 801 players who appear in box scores, so filtering on position alone silently drops real production.
RATES: compute as a sum over a sum, never as an average of per-game rates. Present percentages rounded to one decimal place.
YARDS AND TOUCHDOWNS: report as whole numbers.
GRAIN: one row per player per game. To count games use count(player_game_key); to count distinct players use count(distinct player_key).
SCRIMMAGE YARDS: total_scrimmage is rushing plus receiving and is zero (not null) for a pure passer, so it is safe to sum but do not rank quarterbacks by it.
FANTASY POINTS: two books are available and they are NOT interchangeable. total_fanduel_points is FanDuel scoring (half PPR, -2 per fumble lost); total_draftkings_points is DraftKings Classic scoring (full PPR, -1 per fumble lost); both share 4-point passing TDs, -1 per INT, 3-point yardage bonuses and 2 per two-point conversion. Use the book the user names; if none is named, answer with FanDuel and say "FanDuel scoring" in the answer. Never add or average the two books together. Both cover offensive players only; kickers and team defenses are not scored in this data, and return touchdowns count only for players with offensive involvement in that game.'

ai_question_categorization 'Answer questions about individual offensive production: passing, rushing, receiving, efficiency rates, statistical leaders and per-game output.
If the question is about DEFENSIVE statistics (tackles, sacks recorded, interceptions caught by a defender, passes defended), mark it out of scope and tell the user those live in the player defense view.
If the question is about KICKING, PUNTING or RETURNS, mark it out of scope and point to the special teams data.
If the question asks for NEXT GEN or tracking metrics (completion percentage above expectation, time to throw, separation, yards over expected), mark it out of scope and point to the player advanced view.
If the question is about a TEAM result, record or team-level scoring rather than an individual, mark it out of scope and point to the team performance view.
If the question asks for a rate or average WITHOUT implying a volume threshold, still apply the documented minimum and say so rather than returning a misleading leader.
If the question names a season that is not present in the data, say which seasons are actually available rather than assuming a fixed range.
If a player name is ambiguous or matches multiple players, list the candidates and ask which one they mean.'
