import { get } from '../client.ts'
import type {
  CapabilitiesPayload,
  GamePayload,
  HealthPayload,
  SlatePayload,
  Split,
  StandingsPayload,
  TeamPayload,
} from './types.ts'

const sportPath = (sport: string) => `/api/${encodeURIComponent(sport)}`

export function fetchHealth(signal?: AbortSignal): Promise<HealthPayload> {
  return get<HealthPayload>('/api/health', {}, signal)
}

export function fetchCapabilities(sport: string, signal?: AbortSignal): Promise<CapabilitiesPayload> {
  return get<CapabilitiesPayload>(`${sportPath(sport)}/capabilities`, {}, signal)
}

// a type alias, not an interface: only the alias is assignable to get()'s Record
export type SlateParams = {
  season?: number
  season_type?: string
  week?: number
  vendor?: string
}

/** Undefined params are dropped by get(), so the API resolves the defaults
    (current season, the week in progress, the sport's default book). */
export function fetchSlate(sport: string, params: SlateParams, signal?: AbortSignal): Promise<SlatePayload> {
  return get<SlatePayload>(`${sportPath(sport)}/slate`, params, signal)
}

export function fetchGame(
  sport: string,
  gameKey: string,
  vendor: string | undefined,
  signal?: AbortSignal,
): Promise<GamePayload> {
  return get<GamePayload>(`${sportPath(sport)}/games/${encodeURIComponent(gameKey)}`, { vendor }, signal)
}

export type StandingsParams = {
  season?: number
  season_type?: string
  split?: Split
}

export function fetchStandings(sport: string, params: StandingsParams, signal?: AbortSignal): Promise<StandingsPayload> {
  return get<StandingsPayload>(`${sportPath(sport)}/teams`, params, signal)
}

export type TeamParams = {
  season?: number
  season_type?: string
  vendor?: string
}

export function fetchTeam(sport: string, team: string, params: TeamParams, signal?: AbortSignal): Promise<TeamPayload> {
  return get<TeamPayload>(`${sportPath(sport)}/teams/${encodeURIComponent(team)}`, params, signal)
}
