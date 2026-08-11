import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { fetchPipelinesIndex } from '../api/client.ts'
import type { HeatCell, PipelineIndexRow, PipelinesIndexPayload } from '../api/types.ts'
import { TopBar } from '../components/TopBar.tsx'
import { useSportFilter, ALL_SPORTS } from '../hooks/useSportFilter.ts'
import { dayHhmm, num } from '../utils/format.ts'

/** One rolled-up health per pipeline, computed BEFORE any layout decision:
    the rail dots, the severity sort and the summary counts all read this and
    nothing else. `degraded` = latest run fine but under 80% success over the
    window, which is exactly the "quietly rotting" case a green latest hides. */
type Health = 'failing' | 'never' | 'degraded' | 'healthy'

const SEVERITY: Record<Health, number> = { failing: 3, never: 2, degraded: 1, healthy: 0 }

function health(row: PipelineIndexRow): Health {
  if (row.latest == null) return 'never'
  if (row.latest.state === 'failure' || row.latest.state === 'missing') return 'failing'
  if (row.runs_in_window > 0 && row.succeeded / row.runs_in_window < 0.8) return 'degraded'
  return 'healthy'
}

function successPct(row: PipelineIndexRow): string {
  if (row.runs_in_window === 0) return '·'
  return `${Math.round((100 * row.succeeded) / row.runs_in_window)}%`
}

function relative(at: string, now: string): string {
  const minutes = Math.max(0, Math.round((Date.parse(now) - Date.parse(at)) / 60000))
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h ago`
  const days = Math.floor(hours / 24)
  return days === 1 ? 'yesterday' : `${days} days ago`
}

function cadence(row: PipelineIndexRow): 'daily' | 'weekly' | 'other' {
  if (row.schedule.startsWith('daily')) return 'daily'
  if (row.schedule.startsWith('weekly')) return 'weekly'
  return 'other'
}

function firedToday(row: PipelineIndexRow, now: string): boolean {
  return row.latest != null && row.latest.at.slice(0, 10) === now.slice(0, 10)
}

function MiniStrip({ days }: { days: HeatCell[] }) {
  return (
    <span className="mini" aria-hidden="true">
      {days.map((cell) => (
        <span key={cell.date} className={`mc mc-${cell.state}`} title={`${cell.date} · ${cell.state}`} />
      ))}
    </span>
  )
}

interface ViewSpec {
  id: string
  label: string
  section: 'views' | 'sports' | 'cadence'
  match: (row: PipelineIndexRow) => boolean
}

function buildViews(rows: PipelineIndexRow[], now: string): ViewSpec[] {
  const sports = [...new Set(rows.map((r) => r.sport))].sort()
  return [
    { id: 'all', label: 'All pipelines', section: 'views', match: () => true },
    { id: 'attn', label: 'Needs attention', section: 'views', match: (r) => health(r) !== 'healthy' },
    { id: 'today', label: 'Fired today', section: 'views', match: (r) => firedToday(r, now) },
    ...sports.map(
      (s): ViewSpec => ({ id: `sport:${s}`, label: s, section: 'sports', match: (r) => r.sport === s }),
    ),
    { id: 'daily', label: 'Daily', section: 'cadence', match: (r) => cadence(r) === 'daily' },
    { id: 'weekly', label: 'Weekly', section: 'cadence', match: (r) => cadence(r) === 'weekly' },
  ]
}

function worstOf(rows: PipelineIndexRow[]): Health {
  let worst: Health = 'healthy'
  for (const row of rows) {
    if (SEVERITY[health(row)] > SEVERITY[worst]) worst = health(row)
  }
  return worst
}

function Row({ row, now }: { row: PipelineIndexRow; now: string }) {
  const h = health(row)
  const latest = row.latest
  const pctClass = h === 'failing' ? 'pct bad' : h === 'degraded' ? 'pct warn' : 'pct'
  return (
    <div className="ing-row">
      <span className={`hdot hdot-${h}`} />
      <span className="ing-pipe">
        <Link className="pipe-link" to={`/ingestion/${row.sport}/${row.pipeline}`}>
          {row.pipeline}
        </Link>
        <span className="ing-sched">{row.schedule}</span>
      </span>
      <span className="ing-strip">
        <MiniStrip days={row.days} />
        <span className={pctClass}>{successPct(row)}</span>
      </span>
      <span className="ing-last">
        {latest ? (
          <Link
            className={h === 'failing' ? 'last-run bad' : 'last-run'}
            to={`/runs/${latest.query_id}`}
          >
            {latest.state} · {relative(latest.at, now)}
          </Link>
        ) : (
          <span className="muted">never ran</span>
        )}
      </span>
      <span className="ing-num">{latest?.rows_loaded != null ? num(latest.rows_loaded) : '·'}</span>
      <span className="ing-num">{dayHhmm(row.next_fire)} UTC</span>
    </div>
  )
}

export default function Pipelines() {
  const { sport, setSport } = useSportFilter()
  const [payload, setPayload] = useState<PipelinesIndexPayload | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Sport views live in the shared ?sport= param so deep links from other
  // pages preselect them; the other views are page-local.
  const [localView, setLocalView] = useState<string>('all')
  const [query, setQuery] = useState('')
  const searchRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    const controller = new AbortController()
    setPayload(null)
    setError(null)
    // Always fetch the whole fleet: the rail filters client-side, and every
    // view's count and worst-dot needs all rows anyway.
    fetchPipelinesIndex(ALL_SPORTS, controller.signal)
      .then(setPayload)
      .catch((err: unknown) => {
        if (!(err instanceof DOMException && err.name === 'AbortError')) {
          setError(err instanceof Error ? err.message : String(err))
        }
      })
    return () => controller.abort()
  }, [])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === '/' && document.activeElement !== searchRef.current) {
        e.preventDefault()
        searchRef.current?.focus()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  const rows = useMemo(() => payload?.pipelines ?? [], [payload])
  const views = useMemo(() => (payload ? buildViews(rows, payload.now) : []), [rows, payload])
  const activeId = sport !== ALL_SPORTS ? `sport:${sport}` : localView
  const active = views.find((v) => v.id === activeId) ?? views[0]

  function selectView(view: ViewSpec) {
    if (view.section === 'sports') {
      setSport(view.label)
      setLocalView('all')
    } else {
      setSport(ALL_SPORTS)
      setLocalView(view.id)
    }
  }

  const shown = useMemo(() => {
    if (!active) return []
    const q = query.toLowerCase()
    return rows
      .filter((r) => active.match(r) && (!q || r.pipeline.includes(q)))
      .sort(
        (a, b) => SEVERITY[health(b)] - SEVERITY[health(a)] || a.pipeline.localeCompare(b.pipeline),
      )
  }, [rows, active, query])

  return (
    <>
      <TopBar
        meta={payload ? `${rows.length} pipelines · last ${payload.window_days} days` : null}
      />
      <main className="wrap">
        <h1>Ingestion</h1>
        <p className="subtitle">
          Saved views on the left, one severity-sorted table on the right. Sport list and
          schedules come from DLT_DB.OPS.PIPELINE_REGISTRY.
        </p>
        {error && <p className="load-error">{error}</p>}
        {!payload && !error && <p className="loading">Loading pipelines...</p>}
        {payload && active && (
          <div className="ingest-shell">
            <aside className="views-rail" aria-label="Saved views">
              {(['views', 'sports', 'cadence'] as const).map((section) => (
                <div key={section}>
                  <div className="rail-cap">{section}</div>
                  {views
                    .filter((v) => v.section === section)
                    .map((view) => {
                      const members = rows.filter(view.match)
                      return (
                        <button
                          key={view.id}
                          type="button"
                          className={view.id === active.id ? 'view on' : 'view'}
                          aria-pressed={view.id === active.id}
                          onClick={() => selectView(view)}
                        >
                          <span className={`hdot hdot-${worstOf(members)}`} />
                          {view.label}
                          <span className="n">{members.length}</span>
                        </button>
                      )
                    })}
                </div>
              ))}
            </aside>

            <section className="ingest-main">
              <div className="ingest-toolbar">
                <span className="viewname">{active.label}</span>
                <input
                  ref={searchRef}
                  className="ingest-search"
                  placeholder="/ search within view…"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  aria-label="Search pipelines by name"
                />
                <span className="ingest-count">
                  {shown.length} shown of {rows.length}
                </span>
              </div>
              <div className="ingest-table">
                <div className="ing-hdr">
                  <span />
                  <span>Pipeline</span>
                  <span>Last {payload.window_days} days · success</span>
                  <span>Last run</span>
                  <span className="r">ROWS_LOADED</span>
                  <span className="r">Next fire</span>
                </div>
                {shown.map((row) => (
                  <Row key={row.pipeline} row={row} now={payload.now} />
                ))}
                {shown.length === 0 ? (
                  <p className="ing-empty">No pipeline matches this view and search.</p>
                ) : null}
              </div>
            </section>
          </div>
        )}
      </main>
    </>
  )
}
