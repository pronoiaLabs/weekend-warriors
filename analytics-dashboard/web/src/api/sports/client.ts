import { get } from '../client.ts'
import type {
  BrandingPayload,
  CapabilitiesPayload,
  CatalogPayload,
  GameMarketsPayload,
  GamePayload,
  GameSituationsPayload,
  HealthPayload,
  LeadersPayload,
  MarketsPayload,
  NewsPayload,
  PlayerPayload,
  PlayerPropsPayload,
  PlayerUsagePayload,
  PlaysPayload,
  PulsePayload,
  SheetPayload,
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

export type PulseParams = {
  days?: number
  season?: number
  season_type?: string
  week?: number
  vendor?: string
}

/** The home screen's one fetch: news, status, trending, movers and the slate. */
export function fetchPulse(sport: string, params: PulseParams, signal?: AbortSignal): Promise<PulsePayload> {
  return get<PulsePayload>(`${sportPath(sport)}/pulse`, params, signal)
}

/** Fetched once per sport and cached (useBranding); joined client-side by team_key. */
export function fetchBranding(sport: string, signal?: AbortSignal): Promise<BrandingPayload> {
  return get<BrandingPayload>(`${sportPath(sport)}/teams/branding`, {}, signal)
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

export function fetchGameSituations(
  sport: string,
  gameKey: string,
  signal?: AbortSignal,
): Promise<GameSituationsPayload> {
  return get<GameSituationsPayload>(
    `${sportPath(sport)}/games/${encodeURIComponent(gameKey)}/situations`,
    {},
    signal,
  )
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

export type LeadersParams = {
  season?: number
  season_type?: string
  position?: string
  team?: string
}

export function fetchLeaders(sport: string, params: LeadersParams, signal?: AbortSignal): Promise<LeadersPayload> {
  return get<LeadersPayload>(`${sportPath(sport)}/players`, params, signal)
}

export type PlayerParams = {
  season?: number
  season_type?: string
}

export function fetchPlayer(sport: string, playerKey: string, params: PlayerParams, signal?: AbortSignal): Promise<PlayerPayload> {
  return get<PlayerPayload>(`${sportPath(sport)}/players/${encodeURIComponent(playerKey)}`, params, signal)
}

export function fetchPlayerUsage(
  sport: string,
  playerKey: string,
  params: PlayerParams,
  signal?: AbortSignal,
): Promise<PlayerUsagePayload> {
  return get<PlayerUsagePayload>(
    `${sportPath(sport)}/players/${encodeURIComponent(playerKey)}/usage`,
    params,
    signal,
  )
}

export type PlayerPropsParams = {
  season?: number
  vendor?: string
  stat_key?: string
}

export function fetchPlayerProps(
  sport: string,
  playerKey: string,
  params: PlayerPropsParams,
  signal?: AbortSignal,
): Promise<PlayerPropsPayload> {
  return get<PlayerPropsPayload>(
    `${sportPath(sport)}/players/${encodeURIComponent(playerKey)}/props`,
    params,
    signal,
  )
}

export type PlaysParams = {
  season?: number
  week?: number
  game_key?: string
  player_key?: string
  team?: string
  down_bucket?: string
  distance_bucket?: string
  field_zone?: string
  script?: string
  play_family?: string
  shotgun?: boolean
  no_huddle?: boolean
  two_minute?: boolean
}

export function fetchPlays(sport: string, params: PlaysParams, signal?: AbortSignal): Promise<PlaysPayload> {
  return get<PlaysPayload>(`${sportPath(sport)}/plays`, params, signal)
}

export function fetchMarkets(sport: string, params: SlateParams, signal?: AbortSignal): Promise<MarketsPayload> {
  return get<MarketsPayload>(`${sportPath(sport)}/markets`, params, signal)
}

export function fetchGameMarkets(
  sport: string,
  gameKey: string,
  vendor: string | undefined,
  signal?: AbortSignal,
): Promise<GameMarketsPayload> {
  return get<GameMarketsPayload>(`${sportPath(sport)}/markets/${encodeURIComponent(gameKey)}`, { vendor }, signal)
}

export type NewsParams = {
  days?: number
  team?: string
}

export function fetchNews(sport: string, params: NewsParams, signal?: AbortSignal): Promise<NewsPayload> {
  return get<NewsPayload>(`${sportPath(sport)}/news`, params, signal)
}

export function fetchCatalog(sport: string, signal?: AbortSignal): Promise<CatalogPayload> {
  return get<CatalogPayload>(`${sportPath(sport)}/explore`, {}, signal)
}

export type SheetParams = {
  where: string[]
  q?: string
  order?: string
  desc?: boolean
  limit?: number
  offset?: number
}

/** `where` repeats as column:value (get() appends an array param once per item). */
export function fetchSheet(sport: string, sheet: string, params: SheetParams, signal?: AbortSignal): Promise<SheetPayload> {
  return get<SheetPayload>(`${sportPath(sport)}/explore/${encodeURIComponent(sheet)}`, params, signal)
}
