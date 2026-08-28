{{ config(materialized='semantic_view') }}

/*
    sv_nfl_player_offense -- individual passing, rushing, receiving and usage.

    Grain: player x game (~23,200 rows). One row per player per game in which he
    recorded offensive involvement.

    This is the usage tool: beside the BallDontLie box score it carries
    nflverse usage shares and efficiency (target share, air yards share, WOPR,
    EPA, CPOE, air yards, first downs), Sleeper snap counts and Sleeper league
    fantasy scoring (PPR, half PPR, standard), riding along where the player
    and game bridges match. NULL on a vendor column means no match (and always
    on preseason, which nflverse does not publish), never zero; has_nflverse
    and has_sleeper flag the joins.

    Scope note: this is one of the player phase views. Defensive statistics
    are in sv_nfl_player_defense. A player who contributed in more than one
    phase appears in more than one view; the measure sets are disjoint so
    nothing is double counted, but the views cannot be joined to each other.
    (The former sv_nfl_player_advanced was retired with the BDL advanced
    sources.)

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
    player_games.draftkings_pts as draftkings_points comment = 'DraftKings fantasy points for this player-game under DraftKings Classic scoring (full PPR, -1 per fumble lost). Zero, not null, when nothing scored.',

    -- usage shares (nflverse). NULL on preseason and on rows without an
    -- nflverse match, never zero.
    player_games.target_share as target_share
        with synonyms ('share of targets')
        comment = 'Share of the team''s targets this player drew in THIS game, from nflverse. A per-game ratio with no team-target denominator on this fact, so aggregates of it are averages of games, not exact season shares. NULL on preseason and rows without an nflverse match.',
    player_games.air_yards_share as air_yards_share
        with synonyms ('share of air yards')
        comment = 'Share of the team''s air yards thrown at this player in THIS game, from nflverse. Per-game ratio with no team denominator on this fact. NULL on preseason and rows without an nflverse match.',
    player_games.wopr as wopr
        with synonyms ('weighted opportunity rating')
        comment = 'Weighted opportunity rating: 1.5 x target share plus 0.7 x air yards share, a per-game usage composite from nflverse. Per-game ratio with no team denominator on this fact. NULL on preseason and rows without an nflverse match.',

    -- snaps (Sleeper). The additive snap pair: off_snp over tm_off_snp is the
    -- only sanctioned snap-share computation.
    player_games.off_snp as off_snp
        with synonyms ('offensive snaps', 'snaps played')
        comment = 'Offensive snaps played, from Sleeper. The additive snap source: divide its sum by the sum of tm_off_snp for a true snap share. NULL on rows without a Sleeper match, never zero.',
    player_games.tm_off_snp as tm_off_snp
        with synonyms ('team offensive snaps')
        comment = 'The team''s total offensive snaps in this game, from Sleeper. The denominator for snap share. NULL on rows without a Sleeper match.',
    player_games.off_snap_share as off_snap_share
        with synonyms ('single game snap share')
        comment = 'off_snp divided by tm_off_snp for this single game. For any multi-game span use the snap_share metric, a ratio of sums, never an average of this column. NULL on rows without a Sleeper match.',

    -- efficiency (nflverse). NULL on preseason and unmatched rows, never zero.
    player_games.passing_epa as passing_epa
        with synonyms ('qb epa')
        comment = 'Expected points added on this player''s pass attempts in this game, from nflverse. NULL on preseason and rows without an nflverse match, never zero.',
    player_games.rushing_epa as rushing_epa
        with synonyms ('rush epa')
        comment = 'Expected points added on this player''s carries in this game, from nflverse. NULL on preseason and rows without an nflverse match, never zero.',
    player_games.receiving_epa as receiving_epa
        with synonyms ('rec epa')
        comment = 'Expected points added on targets to this player in this game, from nflverse. NULL on preseason and rows without an nflverse match, never zero.',
    player_games.passing_cpoe as passing_cpoe
        with synonyms ('cpoe', 'completion percentage over expectation')
        comment = 'Completion percentage over expectation on this player''s attempts in this game, from nflverse. NULL on preseason and rows without an nflverse match.',
    player_games.passing_air_yards as passing_air_yards
        with synonyms ('air yards thrown')
        comment = 'Air yards on this player''s pass attempts (distance the ball traveled beyond the line of scrimmage, caught or not), from nflverse. NULL on preseason and rows without an nflverse match.',
    player_games.receiving_air_yards as receiving_air_yards
        with synonyms ('air yards')
        comment = 'Air yards on targets to this player, from nflverse. NULL on preseason and rows without an nflverse match.',
    player_games.passing_first_downs as passing_first_downs
        with synonyms ('first downs passing')
        comment = 'First downs gained on this player''s completions, from nflverse. NULL on preseason and rows without an nflverse match.',
    player_games.rushing_first_downs as rushing_first_downs
        with synonyms ('first downs rushing')
        comment = 'First downs gained on this player''s carries, from nflverse. NULL on preseason and rows without an nflverse match.',
    player_games.receiving_first_downs as receiving_first_downs
        with synonyms ('first downs receiving')
        comment = 'First downs gained on this player''s receptions, from nflverse. NULL on preseason and rows without an nflverse match.',
    player_games.drops as rec_drop
        with synonyms ('dropped passes')
        comment = 'Passes dropped by this player in this game, from Sleeper. NULL on rows without a Sleeper match, never zero.',

    -- Sleeper league fantasy scoring: the actuals of the week under the three
    -- league systems. NULL without a Sleeper match, never zero.
    player_games.pts_ppr as pts_ppr
        with synonyms ('sleeper points')
        comment = 'Sleeper league fantasy points for this game under full PPR scoring. League-scoring actuals, not a DFS book; a bare "fantasy points" or "PPR" question means this column. NULL on rows without a Sleeper match, never zero.',
    player_games.pts_half_ppr as pts_half_ppr
        with synonyms ('half ppr points')
        comment = 'Sleeper league fantasy points for this game under half PPR scoring. NULL on rows without a Sleeper match, never zero.',
    player_games.pts_std as pts_std
        with synonyms ('standard points')
        comment = 'Sleeper league fantasy points for this game under standard, non-PPR scoring. NULL on rows without a Sleeper match, never zero.',
    player_games.pos_rank_ppr as pos_rank_ppr
        with synonyms ('weekly position rank', 'ppr positional rank')
        comment = 'Sleeper''s rank of this player within his position for this week under PPR scoring; 1 is the best week at the position. NULL on rows without a Sleeper match.'
)

dimensions (
    -- who
    players.player_name as full_name
        comment = 'Player full name. High cardinality -- a Cortex Search service would improve fuzzy name matching.'
        sample_values ('Patrick Mahomes', 'Joe Burrow', 'Saquon Barkley', 'Ja''Marr Chase'),
    players.position as position_name
        comment = 'Clean position label, repaired across vendors: BallDontLie first, then nflverse, then Sleeper (position_source records which). Unknown survives only for the small residue no vendor knows; has_known_position flags it.'
        sample_values ('Quarterback', 'Running Back', 'Wide Receiver', 'Tight End', 'Fullback'),
    players.position_group as position_group
        comment = 'Coarse unit grouping, derived from the repaired position. Offensive skill positions are the ones that appear in this view.'
        sample_values ('Offense - Skill', 'Offense - Line', 'Special Teams', 'Unknown'),
    players.college as college
        comment = 'College attended. Null for many players.',
    players.is_rookie as is_rookie
        comment = 'True in a player''s first season.',
    players.draft_year as draft_year
        with synonyms ('year drafted', 'draft class')
        comment = 'Year the player was drafted, from nflverse. NULL for undrafted players and for players without an nflverse match.',
    players.draft_round as draft_round
        with synonyms ('round drafted')
        comment = 'Round the player was drafted in, from nflverse. NULL for undrafted players and for players without an nflverse match.',
    players.college_conference as college_conference
        with synonyms ('conference in college')
        comment = 'Conference the player''s college plays in, from nflverse (SEC, Big Ten, ...). NULL without an nflverse match.',
    players.years_of_experience as years_of_experience
        with synonyms ('nfl experience', 'years in the league')
        comment = 'Seasons of NFL experience, from nflverse. NULL without an nflverse match.',
    players.headshot_url as headshot_url
        with synonyms ('headshot', 'player photo')
        comment = 'URL of the player''s headshot image, from nflverse. Display only; never filter or aggregate on it.',
    players.position_source as position_source
        with synonyms ('position provenance')
        comment = 'Which vendor supplied the repaired position: balldontlie, nflverse or sleeper. NULL only when no vendor knows the position.'
        sample_values ('balldontlie', 'nflverse', 'sleeper') is_enum,
    players.has_known_position as has_known_position
        with synonyms ('position is known')
        comment = 'True when any vendor supplied a position. False for the small residue still listed as Unknown.',

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
        comment = 'True when this player was targeted in this game.',

    -- vendor coverage
    player_games.has_nflverse as has_nflverse
        with synonyms ('nflverse matched')
        comment = 'True when the nflverse block (usage shares, EPA, CPOE, air yards, first downs) is populated for this row. False means those columns are NULL: no bridge match, or preseason, which nflverse does not publish. Filter on it before ranking by those columns.',
    player_games.has_sleeper as has_sleeper
        with synonyms ('sleeper matched')
        comment = 'True when the Sleeper block (pts_ppr, pts_half_ppr, pts_std, snaps, drops) is populated for this row. False means those columns are NULL. Filter on it before ranking by those columns.'
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

    -- fantasy: DFS books. The generic 'fantasy points' synonyms live on the
    -- Sleeper pts_* metrics below; these two keep book-specific synonyms only.
    player_games.total_fanduel_points as sum(player_games.fanduel_pts)
        with synonyms ('fanduel points', 'dfs points', 'fanduel score')
        comment = 'Total FanDuel DFS fantasy points. FanDuel NFL scoring: half PPR, 4-point passing touchdowns, -1 per interception, -2 per fumble lost, 3-point bonuses at 100 rushing or receiving yards and 300 passing yards, 2 per two-point conversion. Offensive players only; kickers and defenses are not scored here. For a bare "fantasy points" question use total_pts_ppr, the Sleeper league scoring, instead.',
    player_games.fanduel_points_per_game as avg(player_games.fanduel_pts)
        with synonyms ('fanduel points per game', 'fanduel average')
        comment = 'Average FanDuel DFS fantasy points per game played.',
    player_games.total_draftkings_points as sum(player_games.draftkings_pts)
        with synonyms ('draftkings points', 'dk points', 'draftkings score')
        comment = 'Total DraftKings fantasy points. DraftKings Classic scoring: full PPR (1 per reception), 4-point passing touchdowns, -1 per interception, -1 per fumble lost, 3-point bonuses at 100 rushing or receiving yards and 300 passing yards, 2 per two-point conversion. Offensive players only; kickers and defenses are not scored here.',
    player_games.draftkings_points_per_game as avg(player_games.draftkings_pts)
        with synonyms ('draftkings points per game', 'dk average')
        comment = 'Average DraftKings DFS fantasy points per game played.',

    -- fantasy: Sleeper league scoring, the default for a bare "fantasy
    -- points" question
    player_games.total_pts_ppr as sum(player_games.pts_ppr)
        with synonyms ('ppr points', 'fantasy points', 'fantasy points ppr')
        comment = 'Total Sleeper league fantasy points under full PPR scoring. The default for a bare "fantasy points" or "PPR" question. League-scoring actuals, not a DFS book; never mix with FanDuel or DraftKings numbers. Games without a Sleeper match are missing, not zero.',
    player_games.total_pts_half_ppr as sum(player_games.pts_half_ppr)
        with synonyms ('total half ppr points')
        comment = 'Total Sleeper league fantasy points under half PPR scoring. Games without a Sleeper match are missing, not zero.',
    player_games.total_pts_std as sum(player_games.pts_std)
        with synonyms ('total standard points', 'non ppr points')
        comment = 'Total Sleeper league fantasy points under standard, non-PPR scoring. Games without a Sleeper match are missing, not zero.',
    player_games.pts_ppr_per_game as avg(player_games.pts_ppr)
        with synonyms ('ppr points per game', 'fantasy points per game')
        comment = 'Average Sleeper PPR points per matched game. Games without a Sleeper match drop out of the average rather than counting as zero.',

    -- efficiency (nflverse). NULL rows are missing data and drop out of the
    -- sums; they are never zero.
    player_games.total_passing_epa as sum(player_games.passing_epa)
        with synonyms ('passing epa total', 'epa as a passer')
        comment = 'Total expected points added on pass attempts, from nflverse. Preseason and unmatched rows are missing, not zero; filter has_nflverse when ranking.',
    player_games.total_rushing_epa as sum(player_games.rushing_epa)
        with synonyms ('rushing epa total', 'epa as a rusher')
        comment = 'Total expected points added on carries, from nflverse. Preseason and unmatched rows are missing, not zero; filter has_nflverse when ranking.',
    player_games.total_receiving_epa as sum(player_games.receiving_epa)
        with synonyms ('receiving epa total', 'epa as a receiver')
        comment = 'Total expected points added on targets, from nflverse. Preseason and unmatched rows are missing, not zero; filter has_nflverse when ranking.',

    -- usage. The share aggregates are unweighted per-game averages by
    -- necessity; only snap share has a true denominator on this fact.
    player_games.snap_share as sum(player_games.off_snp)
                               / nullif(sum(player_games.tm_off_snp), 0)
        with synonyms ('snap pct', 'snap share', 'snap percentage')
        comment = 'Offensive snaps divided by team offensive snaps, a ratio of sums across the selected games, from Sleeper. The only sanctioned snap-share computation; never average off_snap_share. Unmatched rows carry NULL in both columns and drop out.',
    player_games.avg_target_share as avg(player_games.target_share)
        with synonyms ('average target share')
        comment = 'Unweighted average of per-game target shares; no team-target denominator exists on this fact, so do not present as an exact season share.',
    player_games.avg_wopr as avg(player_games.wopr)
        with synonyms ('average wopr', 'average weighted opportunity rating')
        comment = 'Unweighted average of per-game WOPR values; no team denominator exists on this fact, so do not present as an exact season share.',
    player_games.avg_air_yards_share as avg(player_games.air_yards_share)
        with synonyms ('average air yards share')
        comment = 'Unweighted average of per-game air yards shares; no team denominator exists on this fact, so do not present as an exact season share.',
    player_games.total_drops as sum(player_games.rec_drop)
        with synonyms ('total dropped passes')
        comment = 'Total passes dropped, from Sleeper. Games without a Sleeper match are missing, not zero; filter has_sleeper when ranking.'
)

comment = 'Individual NFL offensive production and usage at player-by-game grain, 2023 to 2025 seasons. Covers the passing, rushing and receiving box score for every player who recorded offensive involvement, plus nflverse usage shares and efficiency (target share, air yards share, WOPR, EPA, CPOE, air yards, first downs), Sleeper snap counts and drops, Sleeper league fantasy scoring (PPR, half PPR, standard) and FanDuel and DraftKings DFS points. Use this for statistical leaders, per-game production, efficiency rates, usage shares, snap share and fantasy scoring. Does NOT contain defensive statistics, kicking or returns, player-tracking metrics such as separation or time to throw, or team-level results.'

ai_sql_generation 'DEFAULT TO REGULAR SEASON: unless the user explicitly says preseason, postseason, playoffs, or career/all games, filter season_type = ''Regular Season''.
DEFAULT SEASON: if no season is given, use the most recent season present in the data. Determine that from the data rather than assuming a year.
VOLUME QUALIFIERS ARE MANDATORY FOR RATE STATS: rate metrics are meaningless at low volume. 303 players threw at least one pass in a season but only 139 reached 100 attempts, so an unqualified "best completion percentage" returns a running back who completed a single trick-play pass. When ranking by completion_pct, yards_per_attempt or td_to_int_ratio, require at least 100 pass attempts in the season. When ranking by yards_per_carry require at least 50 carries. When ranking by catch_rate or yards_per_catch require at least 30 targets. State the qualifier you applied in the answer.
IDENTIFY BY ACTIVITY, NOT POSITION: to find quarterbacks use has_passing, running backs has_rushing, receivers has_receiving. The listed position is now repaired across vendors and Unknown survives only for a small residue (has_known_position flags it), but the activity flags remain the robust filter because a listed position does not prove involvement.
RATES: compute as a sum over a sum, never as an average of per-game rates. Present percentages rounded to one decimal place.
YARDS AND TOUCHDOWNS: report as whole numbers.
GRAIN: one row per player per game. To count games use count(player_game_key); to count distinct players use count(distinct player_key).
SCRIMMAGE YARDS: total_scrimmage is rushing plus receiving and is zero (not null) for a pure passer, so it is safe to sum but do not rank quarterbacks by it.
VENDOR COLUMNS ARE NULL, NEVER ZERO: the usage, EPA, CPOE, air yards, first down, snap, drop and pts_* columns come from nflverse and Sleeper joins. They are NULL on preseason (nflverse publishes none) and on rows without a vendor match; never treat those NULLs as zero. When ranking or averaging on those columns, filter has_nflverse = true (usage, EPA, CPOE, air yards, first downs) or has_sleeper = true (snaps, drops, pts_*).
USAGE SHARES ARE PER-GAME: target_share, air_yards_share and wopr are per-game ratios with no team denominator on this fact. Their aggregates (avg_target_share, avg_wopr, avg_air_yards_share) are unweighted averages of games; present them as average per-game shares, never as exact season shares.
SNAP SHARE: always compute as sum(off_snp) / sum(tm_off_snp), which is the snap_share metric, never as an average of the per-game off_snap_share column.
FANTASY POINTS: THREE scoring systems exist and they are NOT interchangeable. Sleeper league scoring (total_pts_ppr, total_pts_half_ppr, total_pts_std) is the actual-of-the-week league scoring; a bare "PPR" or "fantasy points" question means pts_ppr. FanDuel (total_fanduel_points: half PPR, -2 per fumble lost) and DraftKings (total_draftkings_points: full PPR, -1 per fumble lost) are DFS book scorings, shared 4-point passing TDs, -1 per INT, 3-point yardage bonuses and 2 per two-point conversion; use them only when the user names the book or asks about DFS. Name the system used in the answer and never add, average or mix systems in one number. All systems cover offensive players only; kickers and team defenses are not scored in this data.'

ai_question_categorization 'Answer questions about individual offensive production and usage: passing, rushing, receiving, efficiency rates (including EPA and CPOE), air yards, target share, WOPR, snap share, drops, fantasy scoring, statistical leaders and per-game output.
If the question is about DEFENSIVE statistics (tackles, sacks recorded, interceptions caught by a defender, passes defended), mark it out of scope and tell the user those live in the player defense view.
If the question is about KICKING, PUNTING or RETURNS, mark it out of scope and point to the special teams data.
If the question asks for EPA, CPOE, air yards, target share, air yards share, WOPR or snap share, answer it here; those columns are populated for regular season and postseason. Only player-tracking metrics such as separation, time to throw and yards over expected remain unavailable; say so if asked.
If the question asks about official injury designations, filed injury reports, practice participation or depth charts, mark it out of scope and route it to NFLAvailabilityAnalytics.
If the question is about a TEAM result, record or team-level scoring rather than an individual, mark it out of scope and point to the team performance view.
If the question asks for a rate or average WITHOUT implying a volume threshold, still apply the documented minimum and say so rather than returning a misleading leader.
If the question names a season that is not present in the data, say which seasons are actually available rather than assuming a fixed range.
If a player name is ambiguous or matches multiple players, list the candidates and ask which one they mean.'

ai_verified_queries (
    target_share_leaders as (
        question 'Who led the league in target share last season?'
        verified_at 1787788800
        sql 'SELECT player_name, position, avg_target_share, total_targets
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS players.player_name, players.position,
                          player_games.has_nflverse,
                          weeks.season, weeks.season_type
               METRICS player_games.avg_target_share, player_games.total_targets)
             WHERE season = 2025 AND season_type = ''Regular Season''
               AND has_nflverse
               AND total_targets >= 50
             ORDER BY avg_target_share DESC
             LIMIT 10'
    ),
    player_usage_trend as (
        question 'What was Puka Nacua''s week-by-week usage in 2025?'
        verified_at 1787788800
        sql 'SELECT week, avg_target_share, snap_share, total_pts_ppr
             FROM SEMANTIC_VIEW({{ this }}
               METRICS player_games.avg_target_share,
                       player_games.snap_share, player_games.total_pts_ppr
               DIMENSIONS players.player_name, weeks.season,
                          weeks.season_type, weeks.week)
             WHERE player_name = ''Puka Nacua''
               AND season = 2025 AND season_type = ''Regular Season''
             ORDER BY week'
    ),
    ppr_leaders as (
        question 'Who scored the most PPR fantasy points in 2025?'
        verified_at 1787788800
        sql 'SELECT player_name, position, total_pts_ppr
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS players.player_name, players.position,
                          player_games.has_sleeper,
                          weeks.season, weeks.season_type
               METRICS player_games.total_pts_ppr)
             WHERE season = 2025 AND season_type = ''Regular Season''
               AND has_sleeper
             ORDER BY total_pts_ppr DESC
             LIMIT 10'
    )
)
