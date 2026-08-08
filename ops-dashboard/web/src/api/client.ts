import type {
  IncidentCountsPayload,
  IncidentsPayload,
  OverviewPayload,
  SportsPayload,
} from './types.ts'

async function get<T>(
  path: string,
  params: Record<string, string>,
  signal?: AbortSignal,
): Promise<T> {
  const query = new URLSearchParams(params).toString()
  const response = await fetch(query ? `${path}?${query}` : path, {
    headers: { accept: 'application/json' },
    signal,
  })
  if (!response.ok) {
    // FastAPI puts the reason in `detail`; fall back to the status line.
    const body = (await response.json().catch(() => null)) as { detail?: string } | null
    throw new Error(body?.detail ?? `${response.status} ${response.statusText}`)
  }
  return (await response.json()) as T
}

export function fetchSports(signal?: AbortSignal): Promise<SportsPayload> {
  return get<SportsPayload>('/api/sports', {}, signal)
}

export function fetchOverview(sport: string, signal?: AbortSignal): Promise<OverviewPayload> {
  return get<OverviewPayload>('/api/overview', { sport }, signal)
}

export function fetchIncidentCounts(
  sport: string,
  days: number,
  signal?: AbortSignal,
): Promise<IncidentCountsPayload> {
  return get<IncidentCountsPayload>('/api/incidents', { sport, days: String(days) }, signal)
}

/** The whole feed, unfiltered by kind: the chip counts have to describe the
    window rather than the current selection, so the kind filter stays local. */
export function fetchIncidents(
  sport: string,
  days: number,
  signal?: AbortSignal,
): Promise<IncidentsPayload> {
  return get<IncidentsPayload>('/api/incidents', { sport, days: String(days) }, signal)
}
