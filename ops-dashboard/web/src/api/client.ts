import type {
  DbtBuildDetailPayload,
  DbtBuildQueriesPayload,
  DbtBuildsPayload,
  DbtQueryOperatorsPayload,
  HeadlinesPayload,
  LogsPayload,
  MetricsPayload,
  PipelineDetailPayload,
  PipelinesIndexPayload,
  RowCountsPayload,
  RunDetailPayload,
  SlatePayload,
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

/** `date` is omitted rather than sent empty when the caller means today: the API
    resolves the missing parameter against its own clock, which is the one the
    OPS_DASHBOARD_NOW pin moves. */
export function fetchSlate(
  sport: string,
  date: string | null,
  signal?: AbortSignal,
): Promise<SlatePayload> {
  const params: Record<string, string> = { sport }
  if (date) params.date = date
  return get<SlatePayload>('/api/slate', params, signal)
}

export function fetchHeadlines(
  date: string | null,
  signal?: AbortSignal,
): Promise<HeadlinesPayload> {
  const params: Record<string, string> = {}
  if (date) params.date = date
  return get<HeadlinesPayload>('/api/headlines', params, signal)
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

/** `limit` is a caller's decision rather than a page constant: the dashboard
    reads a handful of builds for the day's slate, the builds page reads the
    window it renders. */
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
