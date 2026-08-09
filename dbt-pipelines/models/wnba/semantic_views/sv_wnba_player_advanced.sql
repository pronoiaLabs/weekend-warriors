{{ config(materialized='semantic_view') }}

/*
    sv_wnba_player_advanced -- the advanced season profile: efficiency, ratings,
    usage, scoring distribution, team share and defence.

    Grain: player x season (224 rows), 2026 regular season only.

    THIS VIEW EXISTS, AND ITS NFL COUNTERPART DOES NOT. sv_nfl_player_advanced
    ships disabled because the Next Gen source there tracks each player in
    exactly one discipline: the passing, rushing and receiving endpoints have
    zero player overlap, so a single advanced view would promise
    cross-discipline comparisons the data cannot answer. The WNBA sources have
    the opposite shape. The five endpoints behind this fact -- advanced, misc,
    scoring, usage and defense -- each hold exactly the same 224 players, and
    the five-way inner join returns 224 rows. One unified population means a
    ranking here really is a ranking of everyone, which is precisely what the
    NFL view could not offer.

    A MINIMUM MINUTES FLOOR IS NOT OPTIONAL. The 224 players include 54 with
    fewer than 100 total minutes, and rate statistics on that little playing
    time are noise: true shooting runs to 1.25 and net rating to plus 93.6 on
    single-digit-minute samples. Every leaderboard needs a floor and 100 total
    minutes is the suggested one, which keeps 170 of the 224.

    MINUTES MEANS TWO DIFFERENT THINGS AND BOTH ARE PUBLISHED. The five sources
    disagree: advanced and scoring return minutes PER GAME (27.6), while misc,
    usage and defense return SEASON TOTAL minutes (911.7). They agree on
    exactly 1 of 224 rows, which is coincidence. minutes_per_game and
    total_minutes_played are named for what they are and are not duplicates.

    GAMES PLAYED IS KNOWN TO BE SOFT. The five sources agree on games_played
    for only 204 of the 224 rows, because the endpoints were read at slightly
    different moments and one is a game ahead of another. The value here is the
    advanced endpoint''s. Treat it as accurate to about one game.

    TEAM IS A CURRENT-ROSTER APPROXIMATION. The WNBA source carries no team
    history at all, so team is stamped from the player dimension''s current
    team. 10 of the 224 players changed clubs during the season, and for them
    this attributes the whole season to whichever club they finished with. For
    a historically accurate per-game team, use the player performance view.

    THE _pct SUFFIX COVERS THREE DIFFERENT DENOMINATORS and they are not
    interchangeable:
      * a SHOOTING rate, e.g. true_shooting_pct, denominator is her attempts;
      * a share of HER OWN output, e.g. points_paint_pct, denominator is her
        own points;
      * a share of the TEAM''S output, e.g. rebounds_total_pct, denominator is
        the team total.
    Each fact below says which it is.

    Everything on these endpoints arrives as a 0-1 fraction, matching the
    convention in the other three WNBA views.
*/

tables (
    player_seasons as {{ ref('fact_wnba_player_season_advanced') }}
        primary key (player_season_advanced_key)
        with synonyms ('advanced stats', 'efficiency', 'player season advanced', 'analytics')
        comment = 'One row per player per season: efficiency, ratings, pace, usage, scoring distribution, share of team output and defensive measures. 224 players, 2026 regular season only. Every rate is a 0-1 fraction.',

    players as {{ ref('dim_wnba_player') }}
        primary key (player_key)
        comment = 'Player identity and position. 860 players, of whom 224 have an advanced season profile.',

    teams as {{ ref('dim_wnba_team') }}
        primary key (team_key)
        comment = 'The player''s CURRENT team, not her team at any point in the season. See the view comment on why this is an approximation.'
)

relationships (
    ps_to_player as player_seasons (player_key) references players (player_key),
    ps_to_team as player_seasons (team_key) references teams (team_key)
)

facts (
    -- playing time and record
    player_seasons.games_played as games_played
        comment = 'Games played, 1 to 33. The five underlying endpoints agree on this for only 204 of 224 rows because they were read at slightly different moments, so treat it as accurate to about one game.',
    player_seasons.team_wins_with_player as wins
        comment = 'Team wins in games this player appeared in. A team outcome attributed to a player, not an individual measure.',
    player_seasons.team_losses_with_player as losses
        comment = 'Team losses in games this player appeared in.',
    player_seasons.win_pct as win_pct
        comment = 'Team winning percentage in games this player appeared in, a 0-1 fraction.',
    player_seasons.minutes_per_game as minutes_per_game
        with synonyms ('mpg', 'average minutes')
        comment = 'AVERAGE minutes per game, 0.2 to 34.5. This is a per-game average and is NOT the season total. From the advanced endpoint.',
    player_seasons.total_minutes_played as total_minutes_played
        with synonyms ('total minutes', 'season minutes', 'minutes played')
        comment = 'SEASON TOTAL minutes, 0.2 to 1065.5. A genuinely different measure from minutes_per_game, not a duplicate of it. From the misc endpoint, which is unrounded. This is the column to apply a minimum-minutes floor to.',
    player_seasons.possessions as possessions
        comment = 'Estimated possessions the player was on the floor for.',

    -- headline efficiency
    player_seasons.pie as pie
        with synonyms ('player impact estimate', 'impact')
        comment = 'Player Impact Estimate: the share of the game''s total statistical production this player accounted for. A 0-1 fraction; roughly 0.10 is average and 0.21 led the league. The single best all-in-one measure here.',
    player_seasons.true_shooting_pct as true_shooting_pct
        with synonyms ('ts%', 'true shooting')
        comment = 'True shooting percentage: scoring efficiency charging two-pointers, three-pointers and free throw attempts together. A 0-1 fraction. Reaches 1.25 on tiny samples, so apply a minutes floor.',
    player_seasons.effective_field_goal_pct as effective_field_goal_pct
        with synonyms ('efg', 'effective field goal percentage')
        comment = 'Effective field goal percentage, crediting a three pointer as 1.5 makes. A 0-1 fraction. One of the four factors.',
    player_seasons.usage_pct as usage_pct
        with synonyms ('usage rate', 'usg%', 'offensive load')
        comment = 'Share of her team''s possessions this player finished while on the floor. A 0-1 fraction; 0.32 led the league. Denominator is opportunity, not the team season total.',

    -- ratings
    player_seasons.offensive_rating as offensive_rating
        with synonyms ('ortg', 'offensive efficiency')
        comment = 'Points produced per 100 possessions while on the floor. A rating on a points-per-100 scale, NOT a fraction and NOT a percentage.',
    player_seasons.defensive_rating as defensive_rating
        with synonyms ('drtg', 'defensive efficiency')
        comment = 'Points allowed per 100 possessions while on the floor. LOWER IS BETTER. A points-per-100 scale, not a fraction.',
    player_seasons.net_rating as net_rating
        with synonyms ('net rtg', 'net efficiency')
        comment = 'Offensive rating minus defensive rating, on a points-per-100 scale. Ranges from minus 143.3 to plus 93.6 in this data, and both extremes are tiny-sample artefacts, so apply a minutes floor.',
    player_seasons.pace as pace
        comment = 'Possessions per 48 minutes while on the floor. A tempo measure, not an efficiency one.',

    -- four factors and ball control. Free throw rate, the fourth factor, is
    -- not in the source: there is no FTA over FGA column on any endpoint.
    player_seasons.turnover_pct as team_turnover_pct
        with synonyms ('turnover rate', 'tov%')
        comment = 'Turnovers per possession used. A 0-1 fraction. LOWER IS BETTER. One of the four factors.',
    player_seasons.offensive_rebound_pct as offensive_rebound_pct
        with synonyms ('oreb%', 'offensive rebound rate')
        comment = 'Share of available offensive rebounds collected while on the floor. A 0-1 fraction. One of the four factors.',
    player_seasons.defensive_rebound_pct as defensive_rebound_pct
        with synonyms ('dreb%', 'defensive rebound rate')
        comment = 'Share of available defensive rebounds collected while on the floor. A 0-1 fraction.',
    player_seasons.rebound_pct as rebound_pct
        with synonyms ('reb%', 'total rebound rate')
        comment = 'Share of all available rebounds collected while on the floor. A 0-1 fraction.',
    player_seasons.assist_pct as assist_pct
        with synonyms ('ast%', 'assist rate')
        comment = 'Share of team-mate field goals this player assisted while on the floor. A 0-1 fraction.',
    player_seasons.assist_ratio as assist_ratio
        comment = 'Assists per 100 possessions used. A ratio on a per-100 scale, not a fraction.',
    player_seasons.assist_to_turnover as assist_to_turnover
        with synonyms ('a/to', 'assist to turnover ratio')
        comment = 'Assists divided by turnovers. A plain ratio, typically between 0.5 and 4, not a fraction.',

    -- where her points come from. Denominator is HER OWN output.
    player_seasons.points_from_three_pct as points_3pt_pct
        with synonyms ('share of points from three', 'three point reliance')
        comment = 'Share of THIS PLAYER''S points that came from three pointers. A 0-1 fraction of her own scoring, not a shooting percentage.',
    player_seasons.points_in_paint_pct as points_paint_pct
        with synonyms ('share of points in the paint', 'interior scoring share')
        comment = 'Share of THIS PLAYER''S points scored in the paint. A 0-1 fraction of her own scoring.',
    player_seasons.points_fast_break_pct as points_fast_break_pct
        comment = 'Share of THIS PLAYER''S points scored in transition. A 0-1 fraction of her own scoring.',
    player_seasons.points_off_turnovers_pct as points_off_turnovers_pct
        comment = 'Share of THIS PLAYER''S points scored off opponent turnovers. A 0-1 fraction of her own scoring.',
    player_seasons.assisted_fgm_pct as assisted_fgm_pct
        with synonyms ('assisted rate', 'created for')
        comment = 'Share of THIS PLAYER''S made field goals that were assisted by a team-mate. A 0-1 fraction.',
    player_seasons.unassisted_fgm_pct as unassisted_fgm_pct
        with synonyms ('unassisted rate', 'self created')
        comment = 'Share of THIS PLAYER''S made field goals she created herself. A 0-1 fraction, and the complement of assisted_fgm_pct.',

    -- share of the TEAM total. Same suffix, a different denominator.
    player_seasons.team_points_share as points_pct
        with synonyms ('share of team points', 'scoring share')
        comment = 'Share of the TEAM''S points this player accounted for. A 0-1 fraction whose denominator is the team, not the player.',
    player_seasons.team_assists_share as assists_pct
        comment = 'Share of the TEAM''S assists this player accounted for. A 0-1 fraction of the team total.',
    player_seasons.team_rebounds_share as rebounds_total_pct
        comment = 'Share of the TEAM''S rebounds this player accounted for. A 0-1 fraction of the team total. Distinct from rebound_pct, whose denominator is available rebounds while she was on the floor.',
    player_seasons.team_steals_share as steals_pct
        comment = 'Share of the TEAM''S steals this player accounted for. A 0-1 fraction of the team total.',
    player_seasons.team_blocks_share as blocks_pct
        comment = 'Share of the TEAM''S blocks this player accounted for. A 0-1 fraction of the team total.',
    player_seasons.team_turnovers_share as turnovers_pct
        comment = 'Share of the TEAM''S turnovers this player committed. A 0-1 fraction of the team total.',

    -- defence and fouls. Season totals, not rates.
    player_seasons.steals as steals
        comment = 'Season total steals. From the defense endpoint.',
    player_seasons.blocks as blocks
        comment = 'Season total blocks. From the defense endpoint, which is preferred over the misc endpoint''s copy.',
    player_seasons.defensive_rebounds as defensive_rebounds
        comment = 'Season total defensive rebounds.',
    player_seasons.defensive_win_shares as defensive_win_shares
        with synonyms ('dws', 'defensive win shares')
        comment = 'Estimated wins contributed by this player''s defence over the season. A win count, not a rate.',
    player_seasons.personal_fouls_drawn as personal_fouls_drawn
        comment = 'Season total fouls drawn by this player.',
    player_seasons.blocks_against as blocks_against
        comment = 'Season total shots by this player that were blocked.'
)

dimensions (
    -- who
    players.full_name as full_name
        with synonyms ('player', 'player name', 'athlete')
        comment = 'Player full name. High cardinality; a Cortex Search service would improve fuzzy name matching.'
        sample_values ('A''ja Wilson', 'Breanna Stewart', 'Napheesa Collier', 'Aliyah Boston', 'Caitlin Clark'),
    players.position_name as position_name
        with synonyms ('position', 'listed position')
        comment = 'Clean position label derived from the single-vocabulary position abbreviation. Unknown for players with no position on file.'
        sample_values ('Guard', 'Forward', 'Center', 'Unknown') is_enum,

    -- for whom, approximately
    teams.team_abbreviation as team_abbreviation
        with synonyms ('team', 'club')
        comment = 'Short code of the player''s CURRENT team. This is a roster snapshot and NOT her team through the season: 10 of the 224 players changed clubs and are attributed entirely to the club they finished with. For a per-game team affiliation use the player performance view.'
        sample_values ('LV', 'NY', 'MIN', 'IND', 'PHX', 'SEA', 'WSH', 'ATL', 'DAL'),
    teams.team_full_name as team_full_name
        comment = 'Full name of the player''s current team. Same current-roster caveat as team_abbreviation.'
        sample_values ('Las Vegas Aces', 'New York Liberty', 'Minnesota Lynx', 'Indiana Fever'),
    teams.conference as conference
        comment = 'Eastern Conference or Western Conference for the player''s current team. NULL for the two 2026 expansion clubs, Fire and Tempo, so a conference filter silently drops their players.'
        sample_values ('Eastern Conference', 'Western Conference') is_enum,

    -- when
    player_seasons.season as season
        comment = 'WNBA season. This view holds 2026 only, regular season only. There is no career or multi-season advanced data anywhere in this warehouse.',
    player_seasons.team_count as team_count
        with synonyms ('teams played for', 'changed clubs')
        comment = 'Number of clubs this player appeared for during the season. 2 for the 10 players who were traded or signed elsewhere mid-season, and the flag that their team attribution is unreliable.'
)

metrics (
    -- coverage
    player_seasons.player_count as count(player_seasons.player_season_advanced_key)
        with synonyms ('number of players', 'how many players')
        comment = 'Number of player-seasons in the selection. With a single season in the data this is also the number of players.',
    player_seasons.total_games_played as sum(player_seasons.games_played)
        comment = 'Games played summed across the selection.',
    player_seasons.total_minutes as sum(player_seasons.total_minutes_played)
        comment = 'Season minutes summed across the selection.',

    -- headline efficiency. At one row per player these behave as passthroughs
    -- for a single player and as league or team averages when grouped.
    player_seasons.avg_pie as avg(player_seasons.pie)
        with synonyms ('pie', 'player impact estimate', 'impact')
        comment = 'Player Impact Estimate, a 0-1 fraction. For a single player this is her value; grouped by team or position it is an unweighted mean across players, which gives a 5-minute reserve the same weight as a starter. Apply a minutes floor before grouping.',
    player_seasons.max_pie as max(player_seasons.pie)
        with synonyms ('best pie', 'highest impact')
        comment = 'Highest Player Impact Estimate in the selection.',
    player_seasons.avg_usage_pct as avg(player_seasons.usage_pct)
        with synonyms ('usage rate', 'usage', 'usg%')
        comment = 'Usage rate, a 0-1 fraction. Same unweighted-mean caveat when grouped.',
    player_seasons.avg_true_shooting_pct as avg(player_seasons.true_shooting_pct)
        with synonyms ('true shooting', 'ts%', 'scoring efficiency')
        comment = 'True shooting percentage, a 0-1 fraction. Unusable without a minutes floor: it reaches 1.25 on a single-shot sample.',
    player_seasons.avg_effective_field_goal_pct as avg(player_seasons.effective_field_goal_pct)
        with synonyms ('efg', 'effective field goal percentage')
        comment = 'Effective field goal percentage, a 0-1 fraction.',

    -- ratings
    player_seasons.avg_offensive_rating as avg(player_seasons.offensive_rating)
        with synonyms ('offensive rating', 'ortg')
        comment = 'Points produced per 100 possessions. A points-per-100 scale, never presented as a percentage.',
    player_seasons.avg_defensive_rating as avg(player_seasons.defensive_rating)
        with synonyms ('defensive rating', 'drtg')
        comment = 'Points allowed per 100 possessions. LOWER IS BETTER, so order ascending when ranking.',
    player_seasons.avg_net_rating as avg(player_seasons.net_rating)
        with synonyms ('net rating', 'net rtg')
        comment = 'Offensive minus defensive rating, on a points-per-100 scale. Extremely noisy below a few hundred minutes.',
    player_seasons.avg_pace as avg(player_seasons.pace)
        with synonyms ('pace', 'tempo')
        comment = 'Possessions per 48 minutes while on the floor.',

    -- playing time
    player_seasons.avg_minutes_per_game as avg(player_seasons.minutes_per_game)
        with synonyms ('minutes per game', 'mpg', 'playing time')
        comment = 'Average minutes per game. Distinct from total_minutes, which is a season total.',

    -- rates by area
    player_seasons.avg_assist_pct as avg(player_seasons.assist_pct)
        with synonyms ('assist rate', 'ast%')
        comment = 'Assist rate, a 0-1 fraction.',
    player_seasons.avg_rebound_pct as avg(player_seasons.rebound_pct)
        with synonyms ('rebound rate', 'reb%')
        comment = 'Total rebound rate, a 0-1 fraction. Denominator is available rebounds while on the floor, not the team total.',
    player_seasons.avg_turnover_pct as avg(player_seasons.turnover_pct)
        with synonyms ('turnover rate', 'tov%')
        comment = 'Turnover rate, a 0-1 fraction. LOWER IS BETTER.',
    player_seasons.avg_assist_to_turnover as avg(player_seasons.assist_to_turnover)
        with synonyms ('assist to turnover', 'a/to')
        comment = 'Assists divided by turnovers. A plain ratio, not a fraction, so do not multiply it by 100.',
    player_seasons.avg_points_from_three_pct as avg(player_seasons.points_from_three_pct)
        with synonyms ('three point reliance', 'share of points from three')
        comment = 'Share of a player''s own points from three pointers, a 0-1 fraction. Not a three point shooting percentage.',
    player_seasons.avg_points_in_paint_pct as avg(player_seasons.points_in_paint_pct)
        with synonyms ('interior scoring share')
        comment = 'Share of a player''s own points scored in the paint, a 0-1 fraction. This is a scoring-origin share and is NOT shot location data.',
    player_seasons.avg_unassisted_fgm_pct as avg(player_seasons.unassisted_fgm_pct)
        with synonyms ('self creation', 'unassisted rate')
        comment = 'Share of a player''s own made field goals she created herself, a 0-1 fraction.',
    player_seasons.avg_team_points_share as avg(player_seasons.team_points_share)
        with synonyms ('share of team points', 'scoring share')
        comment = 'Share of the team''s points, a 0-1 fraction. Denominator is the team, not the player.',

    -- defence
    player_seasons.total_steals as sum(player_seasons.steals)
        with synonyms ('steals')
        comment = 'Season steals summed across the selection.',
    player_seasons.total_blocks as sum(player_seasons.blocks)
        with synonyms ('blocks')
        comment = 'Season blocks summed across the selection.',
    player_seasons.total_defensive_win_shares as sum(player_seasons.defensive_win_shares)
        with synonyms ('defensive win shares', 'dws')
        comment = 'Estimated wins contributed by defence, summed across the selection.',
    player_seasons.avg_defensive_rebound_pct as avg(player_seasons.defensive_rebound_pct)
        with synonyms ('defensive rebound rate', 'dreb%')
        comment = 'Defensive rebound rate, a 0-1 fraction.'
)

comment = 'WNBA advanced player metrics at player-by-season grain, 2026 regular season only. 224 players across efficiency (PIE, true shooting, effective field goal), usage, offensive, defensive and net ratings, pace, four factors, scoring distribution, share of team output and defensive measures. This view is ENABLED where its NFL counterpart is disabled, because the five source endpoints behind it cover one identical 224-player population rather than disjoint positional groups, so a ranking here really is a ranking of everyone. Every rate is a 0-1 fraction; ratings are on a points-per-100 scale. Does NOT contain game-level or game-log detail, seasons other than 2026, any career history, postseason or All-Star production, raw box score counting stats such as points and total rebounds, shot location or zone shooting data, or any league rank column.'

ai_sql_generation 'SEASON COVERAGE: 2026 regular season only, one row per player. There is no career data, no earlier season, no postseason and no All-Star row here. If the user asks for a career figure or a season-over-season trend, say the source covers the 2026 regular season only rather than returning a partial answer.
MINIMUM MINUTES FLOOR, THE MOST IMPORTANT RULE IN THIS VIEW: rate statistics on small samples are noise. 54 of the 224 players have under 100 total minutes, and among them true shooting reaches 1.25 and net rating reaches plus 93.6. For ANY leaderboard, ranking, best or worst question about a rate (PIE, true shooting, effective field goal, usage, any rating, any _pct), filter total_minutes_played >= 100 and state the floor in the answer. Raise the floor to 300 minutes if the user asks for the best in the league among regulars. Counting totals such as steals and blocks do not need a floor.
PERCENTAGE SCALE: every _pct fact and every _pct metric in this view is a 0 to 1 fraction. Multiply by 100 and round to one decimal place when presenting, for example 0.619 shown as 61.9%. This is the same convention as the other WNBA views.
NOT EVERYTHING IS A PERCENTAGE: offensive_rating, defensive_rating, net_rating, pace, assist_ratio and possessions are points or events per 100 possessions or per 48 minutes, and assist_to_turnover is a plain ratio. Never multiply any of them by 100 and never label them with a percent sign.
LOWER IS BETTER for defensive_rating and for turnover_pct. Order ascending when ranking on either, and say so.
THREE DIFFERENT DENOMINATORS SHARE THE _pct SUFFIX. A shooting rate (true_shooting_pct, effective_field_goal_pct) divides by her attempts. A share of her own output (points_from_three_pct, points_in_paint_pct, assisted_fgm_pct) divides by her own production. A share of the team (team_points_share, team_rebounds_share, team_steals_share) divides by the team total. They are not interchangeable, so read the fact comment before substituting one for another. In particular points_from_three_pct is the share of her points that came from threes and is NOT her three point shooting percentage.
TWO MINUTES COLUMNS: minutes_per_game is a per-game average and total_minutes_played is a season total. They are different measures, not duplicates, and they agree on exactly 1 of 224 rows by coincidence. Apply floors to total_minutes_played.
TEAM IS A CURRENT-ROSTER APPROXIMATION: the WNBA source carries no team history, so team here is the club the player is on now. 10 players have team_count = 2 and are attributed entirely to the club they finished with. When a team-level answer is given, say that mid-season moves are attributed to the finishing club.
GAMES PLAYED IS SOFT: the five underlying endpoints agree on games_played for only 204 of 224 rows because they were read at different moments. Treat it as accurate to about one game and do not build a precise per-game derivation on it; use the player performance view for anything that needs an exact game count.
NO RANK COLUMNS: the source''s own league rank columns were dropped in the prep layer. Derive any ranking by ordering on the metric itself, after applying a minutes floor.
GROUPING AVERAGES A PLAYER LIST: at one row per player, a metric such as avg_pie grouped by team is an UNWEIGHTED mean over that team''s players, giving a reserve the same weight as a starter. Apply a minutes floor before grouping and say that the average is per player and not minute-weighted.
NO COUNTING STATS: this view carries season totals for steals, blocks and defensive rebounds only. Points, total rebounds and assists as counting totals are in the player performance view.'

ai_question_categorization 'Answer questions about 2026 WNBA advanced player metrics: PIE, true shooting, effective field goal percentage, usage rate, offensive, defensive and net rating, pace, possessions, assist and rebound rates, turnover rate, assist to turnover, scoring distribution, share of team output, defensive win shares and efficiency leaderboards.
If the question is about GAME-LEVEL box score production, a game log, a single game, points, rebounds or assists as counting totals or per-game averages, mark it out of scope and route it to WNBAPlayerPerformanceAnalytics, which holds the box score at player-by-game grain.
If the question is about a TEAM result, record, or team-level box score in the current season, mark it out of scope and route it to WNBATeamPerformanceAnalytics.
If the question is about FRANCHISE HISTORY, standings, playoff seeding or any season before 2026, mark it out of scope and route it to WNBATeamHistoryAnalytics, the only multi-season view in this set.
If the question asks about SHOT LOCATION or distance-based shooting -- shots by zone, from the corner, from five feet, a shot chart, or how a player shoots from a given area -- do NOT attempt an answer from points_in_paint_pct, which is a share of her scoring and not a location. Say that zone and distance shooting data exists in the warehouse CORE tables but is NOT exposed to the Analyst in any semantic view, so it cannot be answered today.
If the question asks for a LEAGUE RANK, explain that rank columns were dropped from the source and that the ranking will be derived by ordering, then state the minimum minutes floor applied.
If the question asks for CAREER or multi-season advanced metrics, explain that this source covers the 2026 regular season only.
If the question asks for POSTSEASON or ALL-STAR advanced metrics, explain that this view is regular season only.
If a player name is ambiguous or matches more than one player, list the candidates and ask which one they mean.
If the question depends on which team a player was on at a point in the season, warn that team here is a current-roster snapshot and point to WNBAPlayerPerformanceAnalytics for per-game affiliation.'
