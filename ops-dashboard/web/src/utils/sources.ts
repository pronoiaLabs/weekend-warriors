/** Display names for the registry's `source` values: the vendor behind each
    pipeline. `rest_api` is the declarative BallDontLie source; the custom
    sources are named for their vendor in dlt-pipelines. A source added
    tomorrow reads as its raw value rather than breaking the chips. */
const LABELS: Record<string, string> = {
  rest_api: 'BallDontLie',
  nflverse: 'nflverse',
  sleeper: 'Sleeper',
  firecrawl: 'Firecrawl',
  openmeteo: 'Open-Meteo',
  snowflake_app: 'Snowflake copy',
  sample: 'Sample',
}

export function sourceLabel(source: string | null | undefined): string {
  if (!source) return 'unknown'
  return LABELS[source] ?? source
}

/** Chip order: vendors in the order they joined the stack, unknowns last. */
const ORDER = Object.keys(LABELS)

export function sortSources(sources: Iterable<string>): string[] {
  return [...new Set(sources)].sort((a, b) => {
    const ia = ORDER.indexOf(a)
    const ib = ORDER.indexOf(b)
    if (ia === -1 && ib === -1) return a.localeCompare(b)
    if (ia === -1) return 1
    if (ib === -1) return -1
    return ia - ib
  })
}
