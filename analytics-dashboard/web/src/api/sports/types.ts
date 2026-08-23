/** Hand-written mirrors of the API's pydantic payloads (api/app/sports/payloads.py
    and the row models in api/app/sports/tiles/). The API-side fixture tests pin the
    keys; /api/openapi.json is the reference when one drifts. */

export type Capability =
  | 'schedule'
  | 'game_prop_board'
  | 'team_performance'
  | 'player_performance'
  | 'game_odds'
  | 'player_props'
  | 'news'

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
  game_status: string | null
  is_completed: boolean
  went_to_overtime: boolean | null
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
