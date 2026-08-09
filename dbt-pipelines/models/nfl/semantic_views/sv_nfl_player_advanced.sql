{{ config(materialized='semantic_view') }}

/*
    sv_nfl_player_advanced -- Next Gen Stats tracking metrics.

    Grain: player x season x week x postseason. Three fact tables, one per
    discipline, all at that identical grain:
      passing   1,639 rows
      rushing   1,637 rows
      receiving 3,762 rows

    THIS VIEW HAS NO GAME DIMENSION. The source carries no game_id, so a metric
    can be tied to a week but never to a specific opponent or game. "His time to
    throw in Week 3" is answerable; "against Dallas" is not.

    SEASON TOTALS ARE EXCLUDED. The source encodes them as week 0 and they do NOT
    reconcile with the sum of the weekly rows (50,025 season-total pass attempts
    against 47,392 summed across weeks). They live in separate season-grain facts
    and are deliberately out of this view, so every number here is a true weekly
    aggregation.

    ONE DISCIPLINE PER PLAYER. Verified: the three facts are mutually exclusive
    by player-season -- zero players appear in any two of them. The source tracks
    each player only in his primary role:
      passing    96 players, all quarterbacks
      rushing   132 players, all running backs (NO quarterbacks)
      receiving 307 players, wide receivers and tight ends (NO running backs)

    Two consequences. Fanout is impossible, so the multi-fact view is safe. But
    cross-discipline questions silently return NULL: a dual-threat quarterback
    has no advanced RUSHING row, and a pass-catching running back has no advanced
    RECEIVING row. That is a source limitation, not a modelling gap, and the
    AI_QUESTION_CATEGORIZATION clause below tells Analyst to say so rather than
    report an empty result as zero.

    What makes these metrics valuable: they measure performance against an
    expectation model rather than raw output. Completion percentage above
    expectation isolates quarterback accuracy from receiver quality and scheme;
    rush yards over expected isolates a runner from his blocking.
*/

tables (
    passing as {{ ref('fact_player_week_advanced_passing') }}
        primary key (player_week_passing_key)
        comment = 'Next Gen passing tracking metrics, one row per quarterback per week. Excludes season totals.',

    rushing as {{ ref('fact_player_week_advanced_rushing') }}
        primary key (player_week_rushing_key)
        comment = 'Next Gen rushing tracking metrics, one row per rusher per week. Excludes season totals.',

    receiving as {{ ref('fact_player_week_advanced_receiving') }}
        primary key (player_week_receiving_key)
        comment = 'Next Gen receiving tracking metrics, one row per receiver per week. Excludes season totals.',

    players as {{ ref('dim_player') }}
        primary key (player_key)
        comment = 'Player biographical attributes. No team column -- this source carries no per-week team affiliation either.',

    weeks as {{ ref('dim_season_week') }}
        primary key (season_week_key)
        comment = 'The NFL calendar. This source covers regular season weeks 1 to 18 and postseason weeks 1 to 5; it never covers preseason.'
)

relationships (
    passing_to_player as passing (player_key) references players (player_key),
    passing_to_week as passing (season_week_key) references weeks (season_week_key),
    rushing_to_player as rushing (player_key) references players (player_key),
    rushing_to_week as rushing (season_week_key) references weeks (season_week_key),
    receiving_to_player as receiving (player_key) references players (player_key),
    receiving_to_week as receiving (season_week_key) references weeks (season_week_key)
)

facts (
    -- passing volume, for use as rate denominators
    passing.att as attempts comment = 'Pass attempts in the week.',
    passing.cmp as completions comment = 'Completions in the week.',
    passing.yds as pass_yards comment = 'Passing yards in the week.',
    passing.tds as pass_touchdowns comment = 'Passing touchdowns in the week.',

    -- passing: expectation model. The headline Next Gen passing measures.
    passing.cpoe as completion_percentage_above_expectation
        comment = 'Completion percentage above expectation, in percentage points. Positive means the quarterback completed more than a model predicts given throw difficulty. Isolates accuracy from receiver and scheme quality.',
    passing.expected_cmp_pct as expected_completion_percentage
        comment = 'Model-predicted completion percentage given the difficulty of the throws attempted.',
    passing.actual_cmp_pct as completion_percentage
        comment = 'Actual completion percentage for the week.',

    -- passing: aggression and air yards
    passing.aggressiveness_pct as aggressiveness
        comment = 'Share of throws made into tight coverage (a defender within one yard of the receiver).',
    passing.air_yards_intended as avg_intended_air_yards
        comment = 'Average intended air yards per attempt: how far downfield the throws were aimed.',
    passing.air_yards_completed as avg_completed_air_yards
        comment = 'Average air yards on completed passes.',
    passing.air_yards_to_sticks as avg_air_yards_to_sticks
        comment = 'Average air yards relative to the first down marker. Negative means throwing short of the sticks.',
    passing.time_to_throw as avg_time_to_throw
        comment = 'Average seconds from snap to release. Around 2.7 to 3.1 seconds is typical.',

    -- rushing volume
    rushing.carries as rush_attempts comment = 'Rushing attempts in the week.',
    rushing.rush_yds as rush_yards comment = 'Rushing yards in the week.',
    rushing.rush_tds as rush_touchdowns comment = 'Rushing touchdowns in the week.',

    -- rushing: expectation model
    rushing.ryoe as rush_yards_over_expected
        comment = 'Rush yards over expected. Positive means the runner gained more than a model predicts given the blocking and defensive alignment. Isolates the runner from his offensive line.',
    rushing.ryoe_per_att as rush_yards_over_expected_per_att
        comment = 'Rush yards over expected per attempt. The rate version, comparable across workloads.',
    rushing.expected_rush_yds as expected_rush_yards
        comment = 'Model-predicted rushing yards given blocking and alignment.',
    rushing.pct_over_expected as rush_pct_over_expected
        comment = 'Percentage by which actual rushing yards exceeded expected.',

    -- rushing: context
    rushing.stacked_box_pct as percent_attempts_gte_eight_defenders
        comment = 'Share of carries faced against eight or more defenders in the box. High values mean the defence was loaded against the run.',
    rushing.time_to_los as avg_time_to_los
        comment = 'Average seconds to reach the line of scrimmage. Lower means a more decisive runner.',
    rushing.rush_efficiency as efficiency
        comment = 'Distance travelled per yard gained. LOWER is better -- a high value means the runner covered a lot of ground for little forward progress.',

    -- receiving volume
    receiving.tgts as targets comment = 'Times targeted in the week.',
    receiving.recs as receptions comment = 'Receptions in the week.',
    receiving.rec_yds as yards comment = 'Receiving yards in the week.',
    receiving.rec_tds as rec_touchdowns comment = 'Receiving touchdowns in the week.',

    -- receiving: separation and coverage
    receiving.separation as avg_separation
        comment = 'Average yards of separation from the nearest defender at the moment the ball arrives. Higher means the receiver was more open.',
    receiving.cushion as avg_cushion
        comment = 'Average yards the defender lined up off the receiver before the snap.',

    -- receiving: expectation model
    receiving.yac as avg_yac
        comment = 'Average yards gained after the catch.',
    receiving.expected_yac as avg_expected_yac
        comment = 'Model-predicted yards after catch given the situation at the catch point.',
    receiving.yac_above_expected as avg_yac_above_expectation
        comment = 'Yards after catch above expectation. Positive means the receiver created more than a model predicts.',

    -- receiving: role in the offence
    receiving.air_yards_share as percent_share_of_intended_air_yards
        comment = 'Share of the team''s total intended air yards directed at this receiver. A measure of how central he is to the passing game.',
    receiving.catch_pct as catch_percentage
        comment = 'Receptions divided by targets, as a percentage.'
)

dimensions (
    players.player_name as full_name
        comment = 'Player full name. High cardinality -- a Cortex Search service would improve fuzzy name matching.'
        sample_values ('Patrick Mahomes', 'Lamar Jackson', 'Saquon Barkley', 'Ja''Marr Chase'),
    players.position as position_name
        comment = 'Clean position label derived from the position abbreviation.'
        sample_values ('Quarterback', 'Running Back', 'Wide Receiver', 'Tight End'),
    players.position_group as position_group
        comment = 'Coarse unit grouping. Only offensive skill positions appear in this view.'
        sample_values ('Offense - Skill', 'Unknown'),

    weeks.season as season
        comment = 'NFL season. Currently covers 2023 to 2025; new seasons are added as they load.',
    weeks.week as week
        comment = 'Week within the season phase. Regular season weeks 1 to 18, postseason weeks 1 to 5. Week 0 season totals are excluded from this view.',
    weeks.season_type as season_type_name
        with synonyms ('regular or playoff')
        comment = 'Regular Season or Postseason only. This source never covers preseason.'
        sample_values ('Regular Season', 'Postseason') is_enum
)

metrics (
    -- passing: weighted rates. Weight by attempts, since a one-attempt week
    -- must not count the same as a forty-attempt week.
    passing.weeks_played as count(passing.player_week_passing_key)
        comment = 'Number of weeks with Next Gen passing data.',
    passing.total_attempts as sum(passing.att)
        comment = 'Total pass attempts across the weeks selected.',
    passing.avg_cpoe as sum(passing.cpoe * passing.att) / nullif(sum(passing.att), 0)
        with synonyms ('cpoe', 'completion percentage above expectation')
        comment = 'Attempt-weighted completion percentage above expectation. The single best available quarterback accuracy measure. Require at least 100 attempts for a ranking to be meaningful.',
    passing.avg_expected_completion_pct as sum(passing.expected_cmp_pct * passing.att) / nullif(sum(passing.att), 0)
        comment = 'Attempt-weighted expected completion percentage.',
    passing.avg_completion_pct as sum(passing.cmp) / nullif(sum(passing.att), 0) * 100
        comment = 'Actual completion percentage, computed from totals rather than averaged across weeks.',
    passing.avg_aggressiveness as sum(passing.aggressiveness_pct * passing.att) / nullif(sum(passing.att), 0)
        with synonyms ('aggressiveness')
        comment = 'Attempt-weighted share of throws into tight coverage.',
    passing.avg_time_to_release as sum(passing.time_to_throw * passing.att) / nullif(sum(passing.att), 0)
        with synonyms ('time to throw', 'time to release')
        comment = 'Attempt-weighted average seconds from snap to release.',
    passing.avg_intended_air as sum(passing.air_yards_intended * passing.att) / nullif(sum(passing.att), 0)
        with synonyms ('intended air yards', 'average depth of target')
        comment = 'Attempt-weighted average intended air yards. Effectively average depth of target.',
    passing.avg_air_to_sticks as sum(passing.air_yards_to_sticks * passing.att) / nullif(sum(passing.att), 0)
        comment = 'Attempt-weighted air yards relative to the first down marker.',

    -- rushing: weighted by carries
    rushing.weeks_rushed as count(rushing.player_week_rushing_key)
        comment = 'Number of weeks with Next Gen rushing data.',
    rushing.total_carries as sum(rushing.carries)
        comment = 'Total rushing attempts across the weeks selected.',
    rushing.total_ryoe as sum(rushing.ryoe)
        with synonyms ('rush yards over expected', 'ryoe')
        comment = 'Total rush yards over expected. Additive, so this is the cumulative measure of value created above the blocking.',
    rushing.avg_ryoe_per_carry as sum(rushing.ryoe) / nullif(sum(rushing.carries), 0)
        with synonyms ('ryoe per carry', 'rush yards over expected per attempt')
        comment = 'Rush yards over expected per carry. The rate version, comparable across workloads. Require at least 50 carries for a ranking.',
    rushing.avg_stacked_box as sum(rushing.stacked_box_pct * rushing.carries) / nullif(sum(rushing.carries), 0)
        with synonyms ('stacked box rate', 'eight or more defenders')
        comment = 'Carry-weighted share of attempts against eight or more defenders in the box.',
    rushing.avg_time_to_line as sum(rushing.time_to_los * rushing.carries) / nullif(sum(rushing.carries), 0)
        comment = 'Carry-weighted average seconds to reach the line of scrimmage.',
    rushing.avg_rush_efficiency as sum(rushing.rush_efficiency * rushing.carries) / nullif(sum(rushing.carries), 0)
        comment = 'Carry-weighted rushing efficiency. LOWER is better.',

    -- receiving: weighted by targets
    receiving.weeks_targeted as count(receiving.player_week_receiving_key)
        comment = 'Number of weeks with Next Gen receiving data.',
    receiving.total_targets as sum(receiving.tgts)
        comment = 'Total targets across the weeks selected.',
    receiving.avg_separation_yards as sum(receiving.separation * receiving.tgts) / nullif(sum(receiving.tgts), 0)
        with synonyms ('separation', 'average separation')
        comment = 'Target-weighted average yards of separation at the catch point. Higher means more open. Require at least 30 targets for a ranking.',
    receiving.avg_cushion_yards as sum(receiving.cushion * receiving.tgts) / nullif(sum(receiving.tgts), 0)
        with synonyms ('cushion')
        comment = 'Target-weighted average pre-snap cushion given by the defender.',
    receiving.avg_yac_actual as sum(receiving.yac * receiving.recs) / nullif(sum(receiving.recs), 0)
        with synonyms ('yards after catch', 'yac')
        comment = 'Reception-weighted average yards after the catch.',
    receiving.avg_yac_over_expected as sum(receiving.yac_above_expected * receiving.recs) / nullif(sum(receiving.recs), 0)
        with synonyms ('yac above expectation', 'yac over expected')
        comment = 'Reception-weighted yards after catch above expectation. Measures how much a receiver creates beyond the model.',
    receiving.avg_air_yards_share as sum(receiving.air_yards_share * receiving.tgts) / nullif(sum(receiving.tgts), 0)
        with synonyms ('air yards share', 'target share of air yards')
        comment = 'Target-weighted share of the team''s intended air yards. High values indicate the primary downfield target.',
    receiving.avg_catch_pct as sum(receiving.recs) / nullif(sum(receiving.tgts), 0) * 100
        comment = 'Catch percentage computed from totals rather than averaged across weeks.'
)

comment = 'NFL Next Gen Stats tracking metrics at player-by-week grain, 2023 to 2025 regular season and postseason. Measures performance against an expectation model rather than raw output: completion percentage above expectation, rush yards over expected, separation, and yards after catch above expectation. Has NO game dimension -- metrics can be tied to a week but never to a specific opponent. Excludes the source''s season-total rows. Does NOT contain traditional box score statistics, defensive tracking, kicking, or team-level data.'

ai_sql_generation 'NO GAME OR OPPONENT: this view has no game or opponent dimension because the source carries no game id. If the user asks about a specific matchup or opponent, explain that Next Gen metrics can only be filtered to a week, not to an opponent.
DEFAULT TO REGULAR SEASON: unless the user says postseason or playoffs, filter season_type = ''Regular Season''. This source has no preseason data at all.
DEFAULT SEASON: if no season is given, use the most recent season present in the data. Determine that from the data rather than assuming a year.
RATES MUST BE VOLUME WEIGHTED: every rate metric here is already defined as a volume-weighted sum over sum (weighted by attempts, carries or targets). Use the provided metrics rather than averaging the underlying weekly facts, because a one-attempt week must not count the same as a forty-attempt week.
VOLUME QUALIFIERS ARE MANDATORY FOR RANKINGS: require at least 100 attempts for passing rate rankings, 50 carries for rushing rate rankings, and 30 targets for receiving rate rankings. State the qualifier you applied.
LOWER IS BETTER for avg_rush_efficiency and avg_time_to_line. Do not describe a high value as good for those two.
UNITS: cpoe, aggressiveness, completion percentage, catch percentage, stacked box rate and air yards share are PERCENTAGES. Time to throw and time to line are SECONDS. Separation, cushion, air yards and yards over expected are YARDS. Always state the unit and round to one decimal place.
SEASON TOTALS ARE NOT HERE: this view holds weekly rows only. Summing across all weeks gives a season figure computed from weekly data, which does NOT match the source''s own published season totals. If the user needs official season totals, say they are in the separate season-grain tables.
ONE DISCIPLINE PER PLAYER: the three tables are mutually exclusive by player -- verified zero overlap. Quarterbacks appear ONLY in passing, running backs ONLY in rushing, and wide receivers and tight ends ONLY in receiving. Never present a NULL from the wrong discipline as a zero. If asked for a dual-threat quarterback''s rush yards over expected, or a running back''s separation, state that the source does not track that player in that discipline rather than returning an empty or zero value.'

ai_question_categorization 'Answer questions about Next Gen Stats tracking metrics: completion percentage above expectation, expected completion percentage, aggressiveness, time to throw, intended air yards, rush yards over expected, stacked box rate, rushing efficiency, separation, cushion, yards after catch above expectation, and air yards share.
If the question asks about a SPECIFIC GAME or OPPONENT, mark it unclear and explain that this source has no game identifier, then offer to answer by week instead.
If the question asks for TRADITIONAL box score statistics (total passing yards, touchdowns, tackles, receptions) rather than tracking metrics, mark it out of scope and point to the player offense or player defense view.
If the question asks for OFFICIAL SEASON TOTALS of these tracking metrics, explain that this view aggregates weekly rows and that the source''s own season totals are held separately and do not reconcile.
If the question asks for DEFENSIVE tracking metrics, coverage grades, or pressure rates, explain that Next Gen data here covers only passing, rushing and receiving.
If the question asks about PRESEASON, explain that this source has no preseason data.
If the question asks for a rate WITHOUT implying a volume threshold, apply the documented minimum and say so rather than returning a one-attempt outlier.
If the question asks for a metric from the WRONG DISCIPLINE for that player -- a quarterback''s rush yards over expected, or a running back''s separation or yards after catch -- explain that the source tracks each player in only one discipline (quarterbacks in passing, running backs in rushing, receivers and tight ends in receiving) and that no data exists for that combination. Do NOT report it as zero.
If a player name is ambiguous or matches multiple players, list the candidates and ask which one they mean.'
