{{ config(materialized='semantic_view') }}

/*
    sv_nfl_team_situation -- situational tendencies from nflverse
    play-by-play. Grain: team x game x side x situation cell, where the
    situation is the full combination of down, distance, field zone, play
    family, shotgun, no-huddle, game script and two-minute flags.

    SIDE, NOT COLUMN PAIRS. Every scrimmage play lands twice: once for the
    offense with side = 'offense', once for the defense with side =
    'defense'. A defense row IS the allowed reading: its EPA is EPA
    allowed, its pass rate the pass rate faced. game_script is the one
    dimension that flips with the side.

    THE ROWS ARE FINE-GRAINED CELLS. A coarse question ("on third down")
    must aggregate across every situation dimension it does not filter,
    which is why only additive components are exposed as facts and every
    rate is a ratio-of-sums metric. The fact's own convenience rate columns
    are deliberately NOT exposed: re-averaging them across cells would
    weight a 3-play cell like a 60-play cell.

    Coverage is regular season and postseason only; nflverse publishes no
    preseason play-by-play.
*/

tables (
    situations as {{ ref('fact_team_game_situation') }}
        primary key (team_game_situation_key)
        with synonyms ('situational splits', 'tendencies', 'situations')
        comment = 'One row per team x game x side x situation cell from nflverse play-by-play. Offense rows are what the team''s offense did; defense rows are what its defense allowed. Additive components only; rates are the metrics.',

    teams as {{ ref('dim_team') }}
        primary key (team_key)
        comment = 'The 32 NFL teams with conference and division.',

    opponents as {{ ref('dim_team') }}
        primary key (team_key)
        with synonyms ('opposing team', 'opponent')
        comment = 'The opposing team in a given game. Same table as teams, joined on opponent_team_key.',

    games as {{ ref('dim_game') }}
        primary key (game_key)
        comment = 'Game context: date and venue. Completed games only reach this fact.'
)

relationships (
    situations_to_team as situations (team_key) references teams (team_key),
    situations_to_opponent as situations (opponent_team_key) references opponents (team_key),
    situations_to_game as situations (game_key) references games (game_key)
)

facts (
    situations.plays as plays
        comment = 'Scrimmage plays in this cell. Additive component; the metrics divide sums of these.',
    situations.epa_sum as epa_sum
        comment = 'Total EPA over the cell''s plays. Additive component; divide by plays via the epa_per_play metric.',
    situations.success_plays as success_plays
        comment = 'Plays graded successful. Additive component behind success_rate.',
    situations.explosive_plays as explosive_plays
        comment = 'Explosive plays: passes of 20+ yards or runs of 10+ yards. Additive component behind explosive_rate.',
    situations.dropbacks as dropbacks
        comment = 'Dropback plays in the cell. Additive component behind pass_rate.',
    situations.carries as carries
        comment = 'Designed runs in the cell. Additive component.',
    situations.yards_sum as yards_sum
        comment = 'Total yards gained over the cell''s plays. Additive component behind yards_per_play.',
    situations.first_downs as first_downs
        comment = 'Plays that gained a first down. Additive component behind first_down_rate.',
    situations.pass_over_expected_sum as pass_over_expected_sum
        comment = 'Sum of pass minus expected pass probability over plays with an xpass model read. Additive component behind proe.',
    situations.xpass_plays as xpass_plays
        comment = 'Plays with an expected-pass model read. The denominator for proe.'
)

dimensions (
    -- which side of the ball this row describes
    situations.side as side
        with synonyms ('offense or defense', 'unit')
        comment = '''offense'' rows are what this team''s offense did; ''defense'' rows are what its defense allowed. The defense row IS the allowed reading.'
        sample_values ('offense', 'defense') is_enum,

    -- the situation itself
    situations.down_bucket as down_bucket
        with synonyms ('down', 'which down')
        comment = 'Down bucket: 1st, 2nd, or 3rd_4th. NULL on two-point tries, which have no down.'
        sample_values ('1st', '2nd', '3rd_4th'),
    situations.distance_bucket as distance_bucket
        with synonyms ('yards to go', 'distance')
        comment = 'Yards-to-go bucket: short (3 or fewer), medium (4 to 7), long (8 or more).'
        sample_values ('short', 'medium', 'long') is_enum,
    situations.field_zone as field_zone
        with synonyms ('field position', 'area of the field')
        comment = 'Field position bucket: red_zone (inside the opponent 20), mid (21 to 50), own (own territory).'
        sample_values ('red_zone', 'mid', 'own') is_enum,
    situations.play_family as play_family
        with synonyms ('pass or run', 'play type')
        comment = 'dropback (pass plays including sacks and scrambles) or designed_run.'
        sample_values ('dropback', 'designed_run') is_enum,
    situations.is_shotgun as is_shotgun
        with synonyms ('from shotgun', 'shotgun formation')
        comment = 'True when the snap was taken from shotgun.',
    situations.is_no_huddle as is_no_huddle
        with synonyms ('no huddle', 'hurry up')
        comment = 'True when the offense went no-huddle.',
    situations.game_script as game_script
        with synonyms ('score situation', 'leading or trailing')
        comment = 'leading, trailing, or neutral from THIS row''s team''s perspective at the snap; on defense rows it is the defending team''s perspective, so it flips with side.'
        sample_values ('leading', 'trailing', 'neutral') is_enum,
    situations.is_two_minute as is_two_minute
        with synonyms ('two minute drill', 'end of half')
        comment = 'True inside the final two minutes of a half.',

    -- when
    situations.season as season
        comment = 'NFL season. Covers 2023 onward.',
    situations.week as week
        comment = 'Week within the season phase. Pair a week filter with season_type.',
    situations.season_type as season_type
        comment = 'Numeric season phase: 2 is Regular Season, 3 is Postseason. Only these two exist here; nflverse publishes no preseason play-by-play.',

    -- who
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

    -- against whom
    opponents.opponent_abbreviation as team_abbreviation
        with synonyms ('opponent code', 'against')
        comment = 'Three-letter code of the opposing team.'
        sample_values ('KC', 'PHI', 'DET', 'BUF'),
    opponents.opponent_full_name as team_full_name
        comment = 'Full name of the opposing team.'
        sample_values ('Kansas City Chiefs', 'Philadelphia Eagles'),

    -- game context
    games.game_date as game_date
        comment = 'Calendar date the game was played.'
)

metrics (
    situations.total_plays as sum(situations.plays)
        with synonyms ('play count', 'sample size', 'number of plays')
        comment = 'Total plays across the selected cells. Use as the volume floor when ranking.',
    situations.epa_per_play as sum(situations.epa_sum) / nullif(sum(situations.plays), 0)
        with synonyms ('epa', 'efficiency', 'expected points added per play')
        comment = 'EPA per play, computed as total EPA over total plays. On defense rows this is EPA allowed, where lower is better.',
    situations.success_rate as sum(situations.success_plays) / nullif(sum(situations.plays), 0)
        with synonyms ('success percentage', 'successful play rate')
        comment = 'Share of plays graded successful, computed as sum over sum.',
    situations.explosive_rate as sum(situations.explosive_plays) / nullif(sum(situations.plays), 0)
        with synonyms ('explosive play rate', 'big play rate')
        comment = 'Share of plays that were explosive (20+ yard passes, 10+ yard runs), sum over sum.',
    situations.pass_rate as sum(situations.dropbacks) / nullif(sum(situations.plays), 0)
        with synonyms ('dropback rate', 'pass frequency')
        comment = 'Share of plays that were dropbacks, sum over sum. On defense rows this is the pass rate faced.',
    situations.proe as sum(situations.pass_over_expected_sum) / nullif(sum(situations.xpass_plays), 0)
        with synonyms ('pass rate over expected', 'pass over expectation')
        comment = 'Pass rate over expected: how much more often the team passed than the model expected, over plays with an xpass read.',
    situations.yards_per_play as sum(situations.yards_sum) / nullif(sum(situations.plays), 0)
        with synonyms ('yards per snap', 'ypp')
        comment = 'Yards per play, computed as total yards over total plays.',
    situations.first_down_rate as sum(situations.first_downs) / nullif(sum(situations.plays), 0)
        with synonyms ('conversion rate', 'first down percentage')
        comment = 'Share of plays that gained a first down, sum over sum.'
)

comment = 'Situational tendencies at team x game x situation grain on nflverse play-by-play, both sides of the ball, with every rate computed sum-over-sum. Offense rows are what a team''s offense did; defense rows are what its defense allowed, in the same columns. Use this for splits by down, distance, field zone, play family, formation flags, game script and two-minute situations. No individual players and no single plays live here.'

ai_sql_generation 'SIDE SEMANTICS: "what does a defense give up" or "allow" means side = ''defense'', and its epa_per_play IS the EPA allowed (lower is better for the defense). Offense questions mean side = ''offense''. Always filter side; mixing sides double-counts every play.
GAME_SCRIPT FLIPS WITH SIDE: it is the ROW''s team''s perspective at the snap, so on defense rows ''leading'' means the defending team was ahead.
THE ROWS ARE FINE-GRAINED CELLS: a coarse question such as "on third down" must aggregate across every situation dimension it does not filter. The metrics already divide sums, so never average per-cell or per-game rates.
VOLUME FLOOR: when ranking teams by any rate, require total_plays >= 50 at minimum, and say the floor was applied.
NULL down_bucket ROWS ARE TWO-POINT TRIES: exclude them from down and distance splits by filtering down_bucket IS NOT NULL.
SEASON PHASES: only regular season (season_type = 2) and postseason (season_type = 3) exist here; nflverse publishes no preseason play-by-play. Default to the regular season unless the user says playoffs or all games.'

ai_question_categorization 'Answer questions about situational tendencies and splits: by down, distance, field zone, dropback versus designed run, shotgun and no-huddle flags, game script, two-minute situations, on either side of the ball, including what a defense allows.
If the question asks for WHOLE-GAME team results, records, scoring, or season form, route it to NFLTeamPerformanceAnalytics.
If the question is about an INDIVIDUAL PLAYER, route it to the player analytics tools.
If the question asks about a SPECIFIC SINGLE PLAY or a play-by-play sequence, decline: this view answers aggregates only, not individual plays.'

ai_verified_queries (
    third_and_long_defenses as (
        question 'Which defenses were best against third-and-long dropbacks in 2025?'
        verified_at 1787788800
        onboarding_question true
        sql 'SELECT team_full_name, epa_per_play, success_rate, total_plays
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS teams.team_full_name, situations.side,
                          situations.down_bucket, situations.distance_bucket,
                          situations.play_family, situations.season
               METRICS situations.epa_per_play, situations.success_rate,
                       situations.total_plays)
             WHERE side = ''defense'' AND down_bucket = ''3rd_4th''
               AND distance_bucket = ''long'' AND play_family = ''dropback''
               AND season = 2025
               AND total_plays >= 50
             ORDER BY epa_per_play'
    ),
    red_zone_offense as (
        question 'Which offenses were most successful in the red zone in 2025?'
        verified_at 1787788800
        sql 'SELECT team_full_name, success_rate, total_plays
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS teams.team_full_name, situations.side,
                          situations.field_zone, situations.season
               METRICS situations.success_rate, situations.total_plays)
             WHERE side = ''offense'' AND field_zone = ''red_zone''
               AND season = 2025
               AND total_plays >= 50
             ORDER BY success_rate DESC'
    ),
    script_pass_rate as (
        question 'How does the Kansas City Chiefs'' pass rate change with game script in 2025?'
        verified_at 1787788800
        sql 'SELECT game_script, pass_rate, proe
             FROM SEMANTIC_VIEW({{ this }}
               DIMENSIONS situations.game_script, situations.side,
                          situations.season, teams.team_full_name
               METRICS situations.pass_rate, situations.proe)
             WHERE team_full_name = ''Kansas City Chiefs''
               AND side = ''offense'' AND season = 2025
             ORDER BY game_script'
    )
)
