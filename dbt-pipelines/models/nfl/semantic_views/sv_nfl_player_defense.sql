{{ config(materialized='semantic_view') }}

/*
    sv_nfl_player_defense -- individual tackling, pass rush and coverage.

    Grain: player x game (~44,600 rows), the largest of the player phase views.

    Two things worth knowing:
      * defensive_sacks is a FLOAT, not an integer. A shared sack counts as 0.5,
        and 1,032 rows carry a half value. Never round it to an integer.
      * sacks here are sacks RECORDED BY this defender. Sacks allowed by an
        offense are in sv_nfl_team_performance and are a different concept.

    The BallDontLie box score is the anchor. The nflverse def_* block (forced
    fumbles, TFL yards, sack yards, safeties, penalties) is a SECOND counting
    system beside it, Sleeper's idp_* columns are a THIRD (the IDP scoring
    inputs), and snap counts come from both nflverse (defense_snaps) and
    Sleeper (def_snp / tm_def_snp, the additive pair). NULL on a vendor column
    means no bridge match, never zero; has_nflverse and has_sleeper flag the
    joins. Coverage grades, pressure rate and missed tackle data still do not
    exist anywhere in the sources.
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
    player_games.def_tds as defensive_touchdowns comment = 'Interception plus fumble return touchdowns.',

    -- snaps: two sources, kept apart. nflverse carries a per-game percentage;
    -- Sleeper carries the additive pair for a true multi-game share.
    player_games.defense_snaps as defense_snaps
        with synonyms ('defensive snaps played')
        comment = 'Defensive snaps played, from nflverse snap counts. NULL on rows without an nflverse match, never zero.',
    player_games.defense_pct as defense_pct
        with synonyms ('single game defensive snap percentage')
        comment = 'Share of the team''s defensive snaps this player played in THIS game, from nflverse. Single-game reading; for any multi-game span use the defense_snap_share metric. NULL without an nflverse match.',
    player_games.def_snp as def_snp
        with synonyms ('sleeper defensive snaps')
        comment = 'Defensive snaps played, from Sleeper. The additive snap source: divide its sum by the sum of tm_def_snp for a true snap share. NULL without a Sleeper match, never zero.',
    player_games.tm_def_snp as tm_def_snp
        with synonyms ('team defensive snaps')
        comment = 'The team''s total defensive snaps in this game, from Sleeper. The denominator for defense_snap_share. NULL without a Sleeper match.',

    -- nflverse def_* block: a second counting system beside the BDL box
    -- score. Never sum a def_* column with its BDL counterpart.
    player_games.def_tackles_for_loss_yards as def_tackles_for_loss_yards
        with synonyms ('tfl yards')
        comment = 'Yards lost on this player''s tackles for loss, from nflverse. Part of a second counting system beside the BDL box score; never sum across systems. NULL without an nflverse match.',
    player_games.def_fumbles_forced as def_fumbles_forced
        with synonyms ('forced fumbles', 'fumbles forced')
        comment = 'Fumbles forced, from nflverse. The BDL box score carries no forced-fumble count, so this is the only reading; distinct from fumbles_recovered. Zero, not NULL, on matched rows with none; NULL without an nflverse match.',
    player_games.def_sack_yards as def_sack_yards
        with synonyms ('sack yardage')
        comment = 'Yards lost by opposing quarterbacks on this player''s sacks, from nflverse. Second counting system; pairs with def_sacks, not with the BDL defensive_sacks. NULL without an nflverse match.',
    player_games.def_safeties as def_safeties
        with synonyms ('safeties')
        comment = 'Safeties recorded, from nflverse. Not in the BDL box score. NULL without an nflverse match.',
    player_games.nflverse_penalties as nflverse_penalties
        with synonyms ('penalties committed')
        comment = 'Penalties committed by this player, from nflverse. Player penalties in general, not defense-specific. NULL without an nflverse match.',
    player_games.nflverse_penalty_yards as nflverse_penalty_yards
        with synonyms ('penalty yards committed')
        comment = 'Yards on penalties committed by this player, from nflverse. NULL without an nflverse match.',

    -- Sleeper idp_* block: the IDP scoring inputs, a third counting system.
    player_games.idp_tkl as idp_tkl
        with synonyms ('idp tackle count')
        comment = 'Tackles under Sleeper''s IDP counting, the scoring input IDP fantasy leagues use. A third system beside the BDL and nflverse readings; never sum across systems. NULL without a Sleeper match, never zero.',
    player_games.idp_sack as idp_sack
        with synonyms ('idp sack count')
        comment = 'Sacks under Sleeper''s IDP counting. Distinct from the BDL defensive_sacks and nflverse def_sacks readings. NULL without a Sleeper match.',
    player_games.idp_int as idp_int
        with synonyms ('idp interception count')
        comment = 'Interceptions under Sleeper''s IDP counting. NULL without a Sleeper match.',
    player_games.idp_ff as idp_ff
        with synonyms ('idp forced fumbles')
        comment = 'Fumbles forced under Sleeper''s IDP counting. Distinct from the nflverse def_fumbles_forced reading. NULL without a Sleeper match.',
    player_games.idp_fum_rec as idp_fum_rec
        with synonyms ('idp fumble recoveries')
        comment = 'Fumbles recovered under Sleeper''s IDP counting. NULL without a Sleeper match.',
    player_games.idp_pass_def as idp_pass_def
        with synonyms ('idp passes defended')
        comment = 'Passes defended under Sleeper''s IDP counting. NULL without a Sleeper match.',
    player_games.idp_qb_hit as idp_qb_hit
        with synonyms ('idp qb hits')
        comment = 'Quarterback hits under Sleeper''s IDP counting. NULL without a Sleeper match.'
)

dimensions (
    -- who
    players.player_name as full_name
        comment = 'Player full name. High cardinality -- a Cortex Search service would improve fuzzy name matching.'
        sample_values ('Micah Parsons', 'Myles Garrett', 'Fred Warner', 'T.J. Watt'),
    players.position as position_name
        comment = 'Clean position label, repaired across vendors: BallDontLie first, then nflverse, then Sleeper (position_source records which). Unknown survives only for the small residue no vendor knows; has_known_position flags it.'
        sample_values ('Linebacker', 'Defensive End', 'Cornerback', 'Safety', 'Defensive Tackle'),
    players.position_group as position_group
        comment = 'Coarse unit grouping, derived from the repaired position. Defensive groups are the ones that appear in this view.'
        sample_values ('Defense - Line', 'Defense - Linebacker', 'Defense - Secondary', 'Unknown'),
    players.college as college
        comment = 'College attended. Null for many players.',
    players.is_rookie as is_rookie
        comment = 'True in a player''s first season.',
    players.draft_year as draft_year
        with synonyms ('year drafted', 'draft class')
        comment = 'Year the player was drafted, from nflverse. NULL for undrafted players and for players without an nflverse match.',
    players.years_of_experience as years_of_experience
        with synonyms ('nfl experience', 'years in the league')
        comment = 'Seasons of NFL experience, from nflverse. NULL without an nflverse match.',
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
        comment = 'Calendar date the game was played.',

    -- vendor coverage
    player_games.has_nflverse as has_nflverse
        with synonyms ('nflverse matched')
        comment = 'True when the nflverse block (def_* columns, defense_snaps, defense_pct) is populated for this row. False means those columns are NULL: no bridge match, or preseason, which nflverse does not publish. Filter on it before ranking by those columns.',
    player_games.has_sleeper as has_sleeper
        with synonyms ('sleeper matched')
        comment = 'True when the Sleeper block (idp_* columns, def_snp, tm_def_snp) is populated for this row. False means those columns are NULL. Filter on it before ranking by those columns.'
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
        comment = 'Touchdowns scored on interception or fumble returns.',

    -- snap share (Sleeper pair, ratio of sums)
    player_games.defense_snap_share as sum(player_games.def_snp)
                                       / nullif(sum(player_games.tm_def_snp), 0)
        with synonyms ('defensive snap pct', 'defensive snap share', 'defensive snap percentage')
        comment = 'Defensive snaps divided by team defensive snaps, a ratio of sums across the selected games, from Sleeper. The only sanctioned multi-game snap-share computation; never average defense_pct. Unmatched rows carry NULL in both columns and drop out.',

    -- forced fumbles (nflverse)
    player_games.total_forced_fumbles as sum(player_games.def_fumbles_forced)
        with synonyms ('total fumbles forced')
        comment = 'Total fumbles forced, from nflverse, the only forced-fumble reading in the sources. Distinct from fumble recoveries. Rows without an nflverse match are missing, not zero; filter has_nflverse when ranking.',

    -- Sleeper IDP: the Sleeper-league IDP tool. Pair these with dropbacks
    -- faced from the team performance view for opportunity volume.
    player_games.total_idp_tackles as sum(player_games.idp_tkl)
        with synonyms ('idp tackles', 'sleeper tackles')
        comment = 'Total tackles under Sleeper''s IDP counting, the Sleeper-league IDP tool; pair with dropbacks faced from the team performance view for opportunity volume. A separate system from total_tackles_made (BDL); never mix systems. Filter has_sleeper when ranking.',
    player_games.total_idp_sacks as sum(player_games.idp_sack)
        with synonyms ('idp sacks', 'sleeper sacks')
        comment = 'Total sacks under Sleeper''s IDP counting, the Sleeper-league IDP tool; pair with dropbacks faced from the team performance view for opportunity volume. A separate system from total_sacks (BDL) and the nflverse def_sacks; never mix systems. Filter has_sleeper when ranking.',
    player_games.total_idp_ints as sum(player_games.idp_int)
        with synonyms ('idp interceptions', 'sleeper interceptions')
        comment = 'Total interceptions under Sleeper''s IDP counting, the Sleeper-league IDP tool; pair with dropbacks faced from the team performance view for opportunity volume. A separate system from total_interceptions (BDL); never mix systems. Filter has_sleeper when ranking.'
)

comment = 'Individual NFL defensive production at player-by-game grain, 2023 to 2025 seasons. Covers the BallDontLie box score (tackling, pass rush, coverage, takeaways), the nflverse def_* block (forced fumbles, TFL yards, sack yards, safeties, penalties) as a second counting system, defensive snap counts from both nflverse and Sleeper, and Sleeper''s IDP scoring inputs. Sacks here are sacks RECORDED BY the defender and are fractional. Does NOT contain offensive statistics, kicking or returns, pressure rates, coverage grades, missed tackles, or team-level results.'

ai_sql_generation 'DEFAULT TO REGULAR SEASON: unless the user explicitly says preseason, postseason, playoffs, or career/all games, filter season_type = ''Regular Season''.
DEFAULT SEASON: if no season is given, use the most recent season present in the data. Determine that from the data rather than assuming a year.
SACKS ARE FRACTIONAL: total_sacks is a FLOAT because a shared sack counts as 0.5. Never cast it to an integer and never round it to a whole number. Present it to one decimal place, for example 17.5.
SACKS DIRECTION: total_sacks counts sacks this defender recorded. If the user asks how many sacks a team ALLOWED, that is an offensive measure in the team performance view, not this one.
INTERCEPTIONS DIRECTION: total_interceptions here means interceptions CAUGHT by a defender. Interceptions thrown by a quarterback are in the player offense view.
IDENTIFY BY ACTIVITY, NOT POSITION: the listed position is now repaired across vendors and Unknown survives only for a small residue (has_known_position flags it), but still prefer filtering on the statistic itself rather than on position. Use position_group only when the user explicitly asks by unit.
RATES: compute as a sum over a sum, never as an average of per-game rates. When ranking by a per-game average require at least 8 games played in the season and say so.
NO PRESSURE DATA: the pressures metric is sacks plus quarterback hits, which is a proxy. If the user asks for true pressure rate, hurries, or missed tackles, say the source does not carry them.
MULTIPLE COUNTING SYSTEMS: three tackle and sack systems coexist and disagree by design: BallDontLie (total_tackles_made, total_sacks and the other box-score metrics), nflverse (the def_* columns) and Sleeper IDP (the idp_* columns and total_idp_* metrics). Name the system used in the answer and never sum or average across systems. A bare "tackles" or "sacks" question means the BallDontLie box score; use idp_* only when the user says IDP, Sleeper or fantasy.
VENDOR COLUMNS ARE NULL, NEVER ZERO: the snap columns, the def_* block and the idp_* columns are NULL where the source has no match; never treat those NULLs as zero. When ranking on defense_snap_share, def_snp or any idp_* column, filter has_sleeper = true; when ranking on defense_snaps, defense_pct or any def_* column, filter has_nflverse = true.
SNAP SHARE: for any multi-game span compute as sum(def_snp) / sum(tm_def_snp), which is the defense_snap_share metric, never as an average of the per-game defense_pct column.
GRAIN: one row per player per game. To count games use count(player_game_key); to count distinct players use count(distinct player_key).'

ai_question_categorization 'Answer questions about individual defensive production: tackles, tackles for loss, sacks, quarterback hits, passes defended, interceptions, fumble recoveries, forced fumbles, takeaways, defensive touchdowns, defensive snap counts and snap share, and Sleeper IDP scoring inputs.
If the question is about OFFENSIVE statistics (passing, rushing, receiving), mark it out of scope and tell the user those live in the player offense view.
If the question is about KICKING, PUNTING or RETURNS, mark it out of scope and point to the special teams data.
If the question asks for NEXT GEN or tracking metrics for defenders, say those are not available in the sources.
If the question is about a TEAM result, record or team-level defense rather than an individual, mark it out of scope and point to the team performance view.
If the question asks about pressure rate, hurries, coverage grades, missed tackles or targets allowed, say the sources do not carry them; snap counts and snap share ARE available here.
If the question is ambiguous about sack DIRECTION (recorded versus allowed) or interception DIRECTION (caught versus thrown), ask the user to clarify before answering.
If the question names a season that is not present in the data, say which seasons are actually available rather than assuming a fixed range.
If a player name is ambiguous or matches multiple players, list the candidates and ask which one they mean.'

ai_verified_queries (
    idp_leaders as (
        question 'Who leads in IDP tackles and sacks this season?'
        verified_at 1787788800
        sql 'SELECT player_name, position, total_idp_tackles, total_idp_sacks
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS players.player_name, players.position,
                          player_games.has_sleeper,
                          weeks.season, weeks.season_type
               METRICS player_games.total_idp_tackles, player_games.total_idp_sacks)
             WHERE season = 2025 AND season_type = ''Regular Season''
               AND has_sleeper
             ORDER BY total_idp_tackles DESC
             LIMIT 10'
    ),
    player_def_snap_trend as (
        question 'What was Fred Warner''s week-by-week defensive snap count in 2025?'
        verified_at 1787788800
        sql 'SELECT week, defense_snap_share, total_idp_tackles
             FROM SEMANTIC_VIEW({{ this }}
               METRICS player_games.defense_snap_share,
                       player_games.total_idp_tackles
               DIMENSIONS players.player_name, weeks.season,
                          weeks.season_type, weeks.week)
             WHERE player_name = ''Fred Warner''
               AND season = 2025 AND season_type = ''Regular Season''
             ORDER BY week'
    )
)
