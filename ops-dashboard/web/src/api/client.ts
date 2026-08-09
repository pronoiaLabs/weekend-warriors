import type {
  DbtBuildDetailPayload,
  DbtBuildQueriesPayload,
  DbtBuildsPayload,
  DbtQueryOperatorsPayload,
  IncidentCountsPayload,
  IncidentsPayload,
  LogsPayload,
  MetricsPayload,
  OverviewPayload,
  PipelineDetailPayload,
  PipelinesIndexPayload,
  RowCountsPayload,
  RunDetailPayload,
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

export function fetchPipelinesIndex(
  sport: string,
  signal?: AbortSignal,
): Promise<PipelinesIndexPayload> {
  return get<PipelinesIndexPayload>('/api/pipelines', { sport }, signal)
}

export function fetchPipelineDetail(
  sport: string,
  name: string,
  limit: number,
  signal?: AbortSignal,
): Promise<PipelineDetailPayload> {
  return get<PipelineDetailPayload>(
    `/api/pipelines/${encodeURIComponent(sport)}/${encodeURIComponent(name)}`,
    { limit: String(limit) },
    signal,
  )
}

export function fetchRun(queryId: string, signal?: AbortSignal): Promise<RunDetailPayload> {
  return get<RunDetailPayload>(`/api/runs/${encodeURIComponent(queryId)}`, {}, signal)
}

/** `severity` is an exact SEVERITY match server side, so only a single level can
    be pushed down; anything broader is narrowed by the caller. */
export function fetchRunLogs(
  queryId: string,
  severity: string | null,
  limit: number,
  signal?: AbortSignal,
): Promise<LogsPayload> {
  const params: Record<string, string> = { limit: String(limit) }
  if (severity) params.severity = severity
  return get<LogsPayload>(`/api/runs/${encodeURIComponent(queryId)}/logs`, params, signal)
}

export function fetchRunMetrics(queryId: string, signal?: AbortSignal): Promise<MetricsPayload> {
  return get<MetricsPayload>(`/api/runs/${encodeURIComponent(queryId)}/metrics`, {}, signal)
}

export function fetchRunRowCounts(
  queryId: string,
  signal?: AbortSignal,
): Promise<RowCountsPayload> {
  return get<RowCountsPayload>(`/api/runs/${encodeURIComponent(queryId)}/rowcounts`, {}, signal)
}

/** `limit` is a caller's decision rather than a page constant: the fleet card
    reads a handful of builds to find the latest per sport, the dbt page reads
    the window it renders. */
export function fetchDbtBuilds(
  sport: string,
  limit: number,
  signal?: AbortSignal,
): Promise<DbtBuildsPayload> {
  return get<DbtBuildsPayload>('/api/dbt/builds', { sport, limit: String(limit) }, signal)
}

export function fetchDbtBuild(
  buildId: string,
  signal?: AbortSignal,
): Promise<DbtBuildDetailPayload> {
  return get<DbtBuildDetailPayload>(`/api/dbt/builds/${encodeURIComponent(buildId)}`, {}, signal)
}

export function fetchDbtBuildQueries(
  buildId: string,
  limit: number,
  signal?: AbortSignal,
): Promise<DbtBuildQueriesPayload> {
  return get<DbtBuildQueriesPayload>(
    `/api/dbt/builds/${encodeURIComponent(buildId)}/queries`,
    { limit: String(limit) },
    signal,
  )
}

export function fetchDbtQueryOperators(
  queryId: string,
  signal?: AbortSignal,
): Promise<DbtQueryOperatorsPayload> {
  return get<DbtQueryOperatorsPayload>(
    `/api/dbt/queries/${encodeURIComponent(queryId)}/operators`,
    {},
    signal,
  )
}
