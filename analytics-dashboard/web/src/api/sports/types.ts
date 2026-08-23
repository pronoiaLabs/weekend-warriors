/** Hand-written mirrors of the API's dict payloads. Kept next to the wrappers
    that return them; the API-side fixture tests pin the keys. */

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
