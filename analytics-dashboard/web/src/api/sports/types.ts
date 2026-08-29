/** Hand-written mirrors of the API's pydantic payloads (api/app/sports/payloads.py
    and the row models in api/app/sports/tiles/). The API-side fixture tests pin the
    keys; /api/openapi.json is the reference when one drifts. */

export type Capability =
  | 'schedule'
  | 'game_prop_board'
  | 'team_standings'
  | 'team_weeks'
  | 'team_allowed'
  | 'team_ats'
  | 'player_leaders'
  | 'player_weeks'
  | 'player_week_stats'
  | 'player_defense_weeks'
  | 'line_history'
  | 'prop_line_history'
  | 'news'
  | 'status_board'
  | 'trending_players'
  | 'market_movers'
  | 'team_branding'
  | 'explore_player_games'
  | 'explore_defender_games'
  | 'explore_team_games'
  | 'explore_game_lines'
  | 'explore_player_props'
  | 'explore_news'
  | 'explore_line_moves'

export interface CapabilitiesPayload {
  sport: string
  label: string
  default_season: number
  capabilities: Capability[]
  extensions: string[]
  vendors: string[]
  default_vendor: string | null
  app_location: string
  as_of: string
  data: 'fixtures' | 'live'
}

export interface HealthPayload {
  ok: boolean
  data: 'fixtures' | 'live'
  backend: 'fixtures' | 'postgres' | 'snowflake'
  role: string
  sports: string[]
  as_of: string
}

/** Every tile envelope: what it answers for, when it was served, the rows, the SQL. */
export interface Envelope<Row> {
  sport: string
  season: number
  as_of: string
  rows: Row[]
  query: string | null
}

export interface WeekRef {
  season: number
  season_type: number
  season_type_name: string
  week: number
  games: number
  completed: number
  first_kickoff: string
  last_kickoff: string
}

/** One game on the board, carrying one book's line (all null when that book has none). */
export interface SlateRow {
  app_game_slate_key: string
  game_key: string
  game_id: number
  season: number
  week: number
  season_type: number
  season_type_name: string
  game_date: string
  game_datetime_et: string
  kickoff_slot_et: string
  kickoff_window: string
  kickoff_window_label: string
  kickoff_window_order: number
  game_status: string | null
  is_completed: boolean
  went_to_overtime: boolean | null
  is_division_game: boolean
  referee: string | null
  home_team_key: string
  home_team_label: string
  home_team_name: string
  home_conference: string | null
  home_division: string | null
  away_team_key: string
  away_team_label: string
  away_team_name: string
  away_conference: string | null
  away_division: string | null
  home_wins: number
  home_losses: number
  home_ties: number
  home_record: string
  away_wins: number
  away_losses: number
  away_ties: number
  away_record: string
  home_players_out: number | null
  home_players_questionable: number | null
  away_players_out: number | null
  away_players_questionable: number | null
  venue: string | null
  stadium_name: string | null
  roof: string | null
  surface: string | null
  is_weather_relevant: boolean | null
  is_international: boolean | null
  kickoff_temp_f: number | null
  wind_mph: number | null
  gust_mph: number | null
  precip_in: number | null
  weather_code: number | null
  forecast_hours_before_kickoff: number | null
  vendor: string | null
  home_spread: number | null
  away_spread: number | null
  home_spread_odds: number | null
  away_spread_odds: number | null
  total_line: number | null
  over_odds: number | null
  under_odds: number | null
  home_moneyline_odds: number | null
  away_moneyline_odds: number | null
  opening_home_spread: number | null
  opening_total_line: number | null
  home_spread_movement: number | null
  total_line_movement: number | null
  implied_home_team_total: number | null
  implied_away_team_total: number | null
  home_moneyline_devig_probability: number | null
  away_moneyline_devig_probability: number | null
  line_selected_at: string | null
  home_spread_result: string | null
  total_result: string | null
  home_score: number | null
  away_score: number | null
  props_open: number
  players_with_props: number
  props_open_all_books: number
  players_with_props_all_books: number
  news_mentions_7d: number
  players_in_news_7d: number
  vendors_available: string[]
}

export interface SlatePayload extends Envelope<SlateRow> {
  season_type_name: string
  week: number
  vendor: string | null
  weeks: WeekRef[]
}

/** One player prop at one book for one game, with the mart's form and matchup columns. */
export interface PropRow {
  app_game_prop_board_key: string
  game_key: string
  season: number
  week: number
  season_type_name: string
  game_datetime_et: string
  is_completed: boolean
  player_key: string
  player_id: number | null
  player_name: string
  position: string | null
  position_name: string | null
  position_group: string | null
  team_key: string | null
  team_label: string | null
  team_name: string | null
  is_home: boolean | null
  opponent_team_key: string | null
  opponent_label: string | null
  opponent_name: string | null
  vendor: string
  prop_type: string
  market_type: string
  stat_key: string | null
  stat_label: string | null
  line_value: number | null
  opening_line_value: number | null
  line_movement: number | null
  over_odds: number | null
  under_odds: number | null
  market_odds: number | null
  opening_over_odds: number | null
  opening_under_odds: number | null
  opening_market_odds: number | null
  line_selected_at: string | null
  trailing_games: number | null
  trailing_avg: number | null
  stat_last3: number[] | null
  trailing_over_line: number | null
  trailing_hit_rate: number | null
  gap_to_line: number | null
  games_played_to_date: number | null
  stat_avg_to_date: number | null
  games_over_line_to_date: number | null
  hit_rate_over_line: number | null
  projection_value: number | null
  projection_vs_line: number | null
  has_projection: boolean
  projection_captured_at: string | null
  usage_trailing3_games: number
  target_share_trailing3: number | null
  air_yards_share_trailing3: number | null
  snap_pct_trailing3: number | null
  opponent_allowed_stat_key: string | null
  opponent_allowed_per_game: number | null
  opponent_allowed_rank: number | null
  opponent_allowed_teams_ranked: number | null
  opponent_allowed_season: number | null
  news_headline: string | null
  news_context: string | null
  news_feed: string | null
  news_published_at: string | null
  actual_value: number | null
  outcome: string | null
}

export interface GamePayload {
  sport: string
  season: number
  as_of: string
  game: SlateRow
  vendors: string[]
  away: PropRow[]
  home: PropRow[]
  query: string | null
}

export interface SituationRow {
  app_team_situation_key: string
  team_key: string
  team_label: string
  team_name: string | null
  season: number
  season_type: number
  season_type_name: string
  side: string
  situation_group: string
  situation_key: string
  situation_label: string
  situation_order: number
  plays: number
  epa_per_play: number | null
  success_rate: number | null
  explosive_rate: number | null
  league_epa_per_play: number | null
  epa_vs_league: number | null
  league_success_rate: number | null
  success_rate_vs_league: number | null
  situation_rank: number | null
  teams_ranked: number | null
}

export interface GameSituationsPayload {
  sport: string
  season: number
  as_of: string
  game_key: string
  season_type_name: string
  situation_season_type_name: string
  home_team_key: string
  home_team_label: string
  away_team_key: string
  away_team_label: string
  home_offense: SituationRow[]
  home_defense: SituationRow[]
  away_offense: SituationRow[]
  away_defense: SituationRow[]
  query: string | null
}

export type Split = 'all' | 'home' | 'away'

/** One team in one season type and split: record, rates and ranks. */
export interface StandingsRow {
  app_team_standings_key: string
  team_key: string
  team_id: number
  team_label: string
  team_name: string
  conference: string | null
  division: string | null
  season: number
  season_type: number
  season_type_name: string
  is_postseason: boolean | null
  split: Split
  games: number
  wins: number
  losses: number
  ties: number
  win_pct: number | null
  points_for: number | null
  points_against: number | null
  point_diff: number | null
  points_for_per_game: number | null
  points_against_per_game: number | null
  point_diff_per_game: number | null
  total_yards: number | null
  plays: number | null
  yards_per_play: number | null
  yards_per_game: number | null
  net_passing_yards: number | null
  rushing_yards: number | null
  third_down_conversions: number | null
  third_down_attempts: number | null
  third_down_pct: number | null
  red_zone_scores: number | null
  red_zone_attempts: number | null
  red_zone_pct: number | null
  turnovers: number | null
  takeaways: number | null
  turnover_margin: number | null
  sacks_allowed: number | null
  sacks_recorded: number | null
  opp_total_yards: number | null
  opp_plays: number | null
  opp_yards_per_play: number | null
  opp_yards_per_game: number | null
  opp_net_passing_yards: number | null
  opp_rushing_yards: number | null
  penalties: number | null
  penalty_yards: number | null
  last_game_date: string | null
  last_results: string[] | null
  rank_overall: number
  rank_conference: number
  rank_division: number
}

export interface StandingsPayload extends Envelope<StandingsRow> {
  season_type_name: string
  split: Split
  season_types: string[]
}

/** One team game with the box score, the running record and one book's line
    from the team's side (all null when that book has none). */
export interface TeamWeekRow {
  app_team_weeks_key: string
  team_game_key: string
  game_key: string
  game_id: number
  team_key: string
  team_id: number
  team_label: string
  team_name: string
  conference: string | null
  division: string | null
  opponent_team_key: string | null
  opponent_label: string | null
  opponent_name: string | null
  season: number
  week: number
  season_type: number
  season_type_name: string
  is_postseason: boolean | null
  game_date: string
  game_datetime_et: string
  kickoff_slot_et: string
  is_home: boolean
  is_completed: boolean
  went_to_overtime: boolean | null
  result: 'W' | 'L' | 'T' | null
  season_game_number: number
  wins_to_date: number
  losses_to_date: number
  ties_to_date: number
  point_diff_to_date: number
  points_for: number
  points_against: number
  point_margin: number
  total_points: number
  points_q1: number | null
  points_q2: number | null
  points_q3: number | null
  points_q4: number | null
  points_ot: number | null
  first_downs: number | null
  total_yards: number | null
  plays: number | null
  yards_per_play: number | null
  net_passing_yards: number | null
  passing_completions: number | null
  passing_attempts: number | null
  yards_per_pass: number | null
  rushing_yards: number | null
  rushing_attempts: number | null
  yards_per_rush_attempt: number | null
  third_down_conversions: number | null
  third_down_attempts: number | null
  third_down_pct: number | null
  fourth_down_conversions: number | null
  fourth_down_attempts: number | null
  red_zone_scores: number | null
  red_zone_attempts: number | null
  red_zone_pct: number | null
  total_drives: number | null
  possession_time_seconds: number | null
  turnovers: number | null
  takeaways: number | null
  turnover_margin: number | null
  fumbles_lost: number | null
  interceptions_thrown: number | null
  sacks_allowed: number | null
  sacks_recorded: number | null
  penalties: number | null
  penalty_yards: number | null
  opp_total_yards: number | null
  opp_yards_per_play: number | null
  opp_net_passing_yards: number | null
  opp_rushing_yards: number | null
  opp_third_down_conversions: number | null
  opp_third_down_attempts: number | null
  opp_red_zone_scores: number | null
  opp_red_zone_attempts: number | null
  opp_turnovers: number | null
  has_box_score: boolean | null
  vendor: string | null
  spread: number | null
  spread_odds: number | null
  moneyline_odds: number | null
  moneyline_devig_probability: number | null
  opening_spread: number | null
  spread_movement: number | null
  total_line: number | null
  opening_total_line: number | null
  total_line_movement: number | null
  over_odds: number | null
  under_odds: number | null
  implied_team_total: number | null
  line_selected_at: string | null
  spread_result: 'cover' | 'push' | 'loss' | null
  margin_vs_spread: number | null
  total_result: 'over' | 'push' | 'under' | null
  vendors_available: string[]
}

/** What a defense allows to one position in one stat, ranked (1 allows the most). */
export interface AllowedRow {
  app_team_allowed_key: string
  team_key: string
  team_id: number
  team_label: string
  team_name: string
  conference: string | null
  division: string | null
  season: number
  season_type: number
  season_type_name: string
  is_postseason: boolean | null
  position: string
  stat_key: string
  defense_games: number
  allowed_total: number
  allowed_per_game: number
  league_avg_per_game: number
  allowed_vs_league: number
  allowed_rank: number
  teams_ranked: number
}

/** A team's record against one book's closing number. */
export interface AtsRow {
  app_team_ats_key: string
  team_key: string
  team_id: number
  team_label: string
  team_name: string
  season: number
  season_type: number
  season_type_name: string
  vendor: string
  games_with_line: number
  ats_wins: number
  ats_losses: number
  ats_pushes: number
  ats_pct: number | null
  overs: number
  unders: number
  total_pushes: number
  over_pct: number | null
  favourite_games: number
  favourite_ats_wins: number
  underdog_games: number
  underdog_ats_wins: number
  home_ats_wins: number
  home_ats_losses: number
  away_ats_wins: number
  away_ats_losses: number
  avg_spread: number | null
  avg_total_line: number | null
  avg_margin_vs_spread: number | null
  avg_total_vs_line: number | null
}

export interface TeamPayload {
  sport: string
  season: number
  as_of: string
  team: StandingsRow
  splits: StandingsRow[]
  season_type_name: string
  season_types: string[]
  vendor: string | null
  vendors: string[]
  weeks: TeamWeekRow[]
  allowed: AllowedRow[]
  ats: AtsRow[]
  query: string | null
}

/** One player's season totals, rates and ranks within the position (1 = most). */
export interface LeadersRow {
  app_player_leaders_key: string
  player_key: string
  player_id: number | null
  player_name: string
  position: string | null
  position_name: string | null
  position_group: string | null
  team_key: string | null
  team_label: string | null
  team_name: string | null
  teams_count: number
  season: number
  season_type: number
  season_type_name: string
  is_postseason: boolean | null
  games: number
  first_game_date: string
  last_game_date: string
  passing_attempts: number | null
  passing_completions: number | null
  passing_yards: number | null
  passing_touchdowns: number | null
  passing_interceptions: number | null
  times_sacked: number | null
  completion_pct: number | null
  yards_per_pass_attempt: number | null
  rushing_attempts: number | null
  rushing_yards: number | null
  rushing_touchdowns: number | null
  long_rushing: number | null
  yards_per_rush_attempt: number | null
  receiving_targets: number | null
  receptions: number | null
  receiving_yards: number | null
  receiving_touchdowns: number | null
  long_reception: number | null
  yards_per_reception: number | null
  catch_rate: number | null
  fumbles: number | null
  fumbles_lost: number | null
  scrimmage_yards: number | null
  scrimmage_touchdowns: number | null
  scoring_touchdowns: number | null
  touches: number | null
  two_point_conversions: number | null
  fanduel_points: number | null
  draftkings_points: number | null
  games_with_passing: number
  games_with_rushing: number
  games_with_receiving: number
  passing_yards_per_game: number | null
  rushing_yards_per_game: number | null
  receiving_yards_per_game: number | null
  receptions_per_game: number | null
  targets_per_game: number | null
  scrimmage_yards_per_game: number | null
  touches_per_game: number | null
  fanduel_points_per_game: number | null
  draftkings_points_per_game: number | null
  rank_passing_yards: number
  rank_passing_touchdowns: number
  rank_rushing_yards: number
  rank_rushing_touchdowns: number
  rank_receiving_yards: number
  rank_receptions: number
  rank_receiving_touchdowns: number
  rank_scrimmage_yards: number
  rank_scoring_touchdowns: number
  rank_fanduel_points: number
  rank_draftkings_points: number
  rank_fanduel_points_per_game: number
  rank_draftkings_points_per_game: number
  players_at_position: number
}

export interface LeadersPayload extends Envelope<LeadersRow> {
  season_type_name: string
  season_types: string[]
  position: string | null
  team: string | null
}

/** One player game: the box score, the team result and running fantasy totals. */
export interface PlayerWeekRow {
  app_player_weeks_key: string
  player_game_key: string
  game_key: string
  game_id: number
  player_key: string
  player_id: number | null
  player_name: string
  position: string | null
  position_name: string | null
  position_group: string | null
  team_key: string | null
  team_id: number | null
  team_label: string | null
  team_name: string | null
  opponent_team_key: string | null
  opponent_label: string | null
  opponent_name: string | null
  is_home: boolean | null
  season: number
  week: number
  season_type: number
  season_type_name: string
  is_postseason: boolean | null
  game_date: string
  game_datetime_et: string
  is_completed: boolean
  team_result: 'W' | 'L' | 'T' | null
  team_points: number | null
  opponent_points: number | null
  games_to_date: number
  passing_attempts: number | null
  passing_completions: number | null
  passing_yards: number | null
  yards_per_pass_attempt: number | null
  passing_touchdowns: number | null
  passing_interceptions: number | null
  times_sacked: number | null
  sack_yards_lost: number | null
  qb_rating: number | null
  qbr: number | null
  rushing_attempts: number | null
  rushing_yards: number | null
  yards_per_rush_attempt: number | null
  rushing_touchdowns: number | null
  long_rushing: number | null
  receiving_targets: number | null
  receptions: number | null
  receiving_yards: number | null
  yards_per_reception: number | null
  receiving_touchdowns: number | null
  long_reception: number | null
  fumbles: number | null
  fumbles_lost: number | null
  scrimmage_yards: number | null
  scrimmage_touchdowns: number | null
  scoring_touchdowns: number | null
  touches: number | null
  has_passing: boolean | null
  has_rushing: boolean | null
  has_receiving: boolean | null
  two_point_conversions: number | null
  two_point_conversions_thrown: number | null
  fanduel_points: number | null
  draftkings_points: number | null
  fanduel_points_to_date: number | null
  draftkings_points_to_date: number | null
  scrimmage_yards_to_date: number | null
}

/** One stat in one game with the trailing and prior-season comparisons. */
export interface PlayerStatRow {
  app_player_week_stats_key: string
  player_game_key: string
  game_key: string
  player_key: string
  player_name: string
  position: string | null
  team_key: string | null
  team_label: string | null
  season: number
  week: number
  season_type: number
  season_type_name: string
  game_date: string
  stat_key: string
  value: number
  games_through: number
  trailing3_avg: number | null
  season_avg_through: number | null
  season_total_through: number | null
  prior_season_same_week: number | null
  prior_season_avg: number | null
  prior_season_games: number | null
  avg_vs_prior_season: number | null
}

export interface PlayerPayload {
  sport: string
  season: number
  as_of: string
  player: LeadersRow
  seasons: LeadersRow[]
  season_type_name: string
  season_types: string[]
  weeks: PlayerWeekRow[]
  stats: PlayerStatRow[]
  query: string | null
}

/** One pregame snapshot of a game's line at a book, kept only where it moved. */
export interface LineRow {
  app_line_history_key: string
  game_vendor_odds_key: string
  game_key: string
  game_id: number
  season: number
  week: number
  season_type: number
  season_type_name: string
  game_date: string
  game_datetime_et: string
  is_completed: boolean
  home_team_key: string
  home_team_label: string | null
  home_team_name: string | null
  away_team_key: string
  away_team_label: string | null
  away_team_name: string | null
  vendor: string
  snapshot_number: number
  snapshots_before_kickoff: number
  is_opening: boolean
  is_closing: boolean
  snapshot_observed_at: string
  prev_snapshot_observed_at: string | null
  minutes_before_kickoff: number | null
  hours_before_kickoff: number | null
  home_spread: number | null
  home_spread_odds: number | null
  away_spread: number | null
  away_spread_odds: number | null
  home_moneyline_odds: number | null
  away_moneyline_odds: number | null
  total_line: number | null
  over_odds: number | null
  under_odds: number | null
  home_spread_change: number | null
  total_line_change: number | null
  home_moneyline_odds_change: number | null
  away_moneyline_odds_change: number | null
  home_spread_since_open: number | null
  total_line_since_open: number | null
}

export interface MarketsPayload extends Envelope<LineRow> {
  season_type_name: string
  week: number
  vendor: string | null
  weeks: WeekRef[]
}

/** One pregame snapshot of a player prop at a book. */
export interface PropLineRow {
  app_prop_line_history_key: string
  game_player_vendor_prop_key: string
  game_key: string
  game_id: number
  player_key: string
  player_id: number | null
  player_name: string | null
  position: string | null
  season: number
  week: number
  season_type: number
  season_type_name: string
  game_date: string
  game_datetime_et: string
  is_completed: boolean
  home_team_key: string
  home_team_label: string | null
  away_team_key: string
  away_team_label: string | null
  vendor: string
  prop_type: string
  market_type: string
  stat_key: string | null
  stat_label: string | null
  snapshot_number: number
  snapshots_before_kickoff: number
  is_opening: boolean
  is_closing: boolean
  snapshot_observed_at: string
  prev_snapshot_observed_at: string | null
  minutes_before_kickoff: number | null
  hours_before_kickoff: number | null
  line_value: number | null
  market_odds: number | null
  over_odds: number | null
  under_odds: number | null
  line_value_change: number | null
  market_odds_change: number | null
  over_odds_change: number | null
  under_odds_change: number | null
  line_value_since_open: number | null
}

export interface GameRef {
  game_key: string
  season: number
  week: number
  season_type_name: string
  game_date: string
  game_datetime_et: string
  is_completed: boolean
  home_team_label: string | null
  home_team_name: string | null
  away_team_label: string | null
  away_team_name: string | null
}

export interface GameMarketsPayload {
  sport: string
  season: number
  as_of: string
  game: GameRef
  vendor: string | null
  vendors: string[]
  lines: LineRow[]
  props: PropLineRow[]
  query: string | null
}

/** One player mention in an article, with the team's next game attached. */
export interface MentionRow {
  app_news_mentions_key: string
  mention_key: string
  article_key: string
  player_key: string | null
  player_id: number | null
  is_player_resolved: boolean
  player_name: string | null
  position: string | null
  position_name: string | null
  position_group: string | null
  headshot_url: string | null
  sleeper_player_id: string | null
  team_key: string | null
  team_label: string | null
  team_name: string | null
  published_at: string
  published_date: string
  feed: string
  headline: string | null
  context: string | null
  detail: string | null
  url: string | null
  player_name_in_article: string | null
  team_in_article: string | null
  extract_mode: string | null
  resolution_method: string | null
  candidate_count: number | null
  next_game_key: string | null
  next_game_datetime_et: string | null
  next_game_season: number | null
  next_game_week: number | null
  next_game_season_type_name: string | null
  next_opponent_team_key: string | null
  next_opponent_label: string | null
  next_opponent_name: string | null
  next_game_is_home: boolean | null
  days_to_next_game: number | null
}

export interface NewsPayload extends Envelope<MentionRow> {
  since: string
  days: number
  team: string | null
  feeds: string[]
  teams: string[]
}

/** The Explorer: a sheet is one flat table, its columns typed for a grid. */
export type Kind = 'integer' | 'number' | 'text' | 'boolean' | 'date' | 'datetime'

export interface SheetColumn {
  name: string
  kind: Kind
  type: string
}

export interface SheetRef {
  id: string
  cap: Capability
  table: string
  label: string
  description: string
  columns: SheetColumn[]
}

export interface CatalogPayload {
  sport: string
  as_of: string
  sheets: SheetRef[]
  query: string | null
}

export type Cell = string | number | boolean | null

export interface SheetPayload {
  sport: string
  season: number
  as_of: string
  sheet: string
  table: string
  columns: SheetColumn[]
  filters: { column: string; value: Cell }[]
  order: string
  desc: boolean
  limit: number
  offset: number
  has_more: boolean
  rows: Record<string, Cell>[]
  query: string | null
}

/** The Pulse: the home screen's composite fetch, five sections in one payload. */
export interface StatusRow {
  app_status_board_key: string
  player_key: string
  player_id: number | null
  player_name: string
  position: string | null
  position_name: string | null
  position_group: string | null
  headshot_url: string | null
  sleeper_player_id: string | null
  team_key: string | null
  team_label: string | null
  team_name: string | null
  status_source: 'report' | 'live'
  designation: string | null
  designation_order: number
  injury: string | null
  injury_detail: string | null
  practice_status: string | null
  practice_wed: string | null
  practice_thu: string | null
  practice_fri: string | null
  report_modified_at: string | null
  live_injury_status: string | null
  live_practice_participation: string | null
  depth_chart_position: string | null
  depth_chart_order: number | null
  news_updated_at: string | null
  backup_player_key: string | null
  backup_player_name: string | null
  backup_depth_rank: number | null
  ripple_note: string | null
  game_key: string | null
  game_datetime_et: string | null
  season: number | null
  week: number | null
  season_type_name: string | null
  opponent_team_key: string | null
  opponent_label: string | null
  is_home: boolean | null
}

export interface TrendingRow {
  app_trending_players_key: string
  player_key: string
  player_id: number | null
  sleeper_player_id: string | null
  player_name: string
  position: string | null
  position_name: string | null
  position_group: string | null
  headshot_url: string | null
  team_key: string | null
  team_label: string | null
  team_name: string | null
  direction: 'add' | 'drop'
  move_count_24h: number
  board_rank: number | null
  lookback_hours: number | null
  fetched_at: string
  trend_date: string
  state_season: number | null
  state_week: number | null
  next_game_key: string | null
  next_game_datetime_et: string | null
  next_opponent_team_key: string | null
  next_opponent_label: string | null
  next_game_is_home: boolean | null
}

export interface MoverRow {
  app_market_movers_key: string
  kind: 'game' | 'prop'
  game_key: string
  game_id: number
  season: number
  week: number
  season_type: number
  season_type_name: string
  game_date: string
  game_datetime_et: string
  vendor: string
  market: string
  home_team_key: string | null
  home_team_label: string | null
  away_team_key: string | null
  away_team_label: string | null
  player_key: string | null
  player_id: number | null
  player_name: string | null
  position: string | null
  headshot_url: string | null
  team_key: string | null
  team_label: string | null
  stat_label: string | null
  open_line: number
  latest_line: number
  delta: number
  abs_delta: number
  open_at: string | null
  moved_at: string | null
  snapshots: number | null
  mover_rank: number
}

export interface MoversSection {
  games: MoverRow[]
  props: MoverRow[]
}

export interface PulsePayload {
  sport: string
  season: number
  as_of: string
  season_type_name: string
  week: number
  days: number
  vendor: string | null
  weeks: WeekRef[]
  slate: SlateRow[]
  news: MentionRow[]
  status: StatusRow[]
  trending: TrendingRow[]
  movers: MoversSection
  query: string | null
}

/** Team branding: fetched once per sport, joined client-side by team_key. */
export interface BrandingRow {
  app_team_branding_key: string
  team_key: string
  team_id: number
  team_label: string
  team_name: string
  team_nickname: string | null
  conference: string | null
  division: string | null
  nflverse_abbr: string | null
  color_primary: string | null
  color_secondary: string | null
  logo_url: string | null
  logo_squared_url: string | null
  wordmark_url: string | null
}

export type BrandingPayload = Envelope<BrandingRow>
