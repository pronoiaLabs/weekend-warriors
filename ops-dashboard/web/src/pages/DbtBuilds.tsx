import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { fetchDbtBuilds } from '../api/client.ts'
import type { DbtBuildRow, DbtBuildsPayload } from '../api/types.ts'
import { DbtStateChip } from '../components/DbtStateChip.tsx'
import { SectionHead } from '../components/SectionHead.tsx'
import { TopBar } from '../components/TopBar.tsx'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { duration, elapsedMs, num, relativeTo } from '../utils/format.ts'

const BUILD_LIMIT = 50

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

/** The payload carries no `now`, so the newest thing it describes stands in for
    one, the way the pipeline detail page does it: the browser clock would age a
    stale tab all by itself. */
function reference(builds: DbtBuildRow[]): string | null {
  const stamps = builds
    .flatMap((build) => [build.completed_time, build.started_at, build.scheduled_time])
    .filter((value): value is string => value != null)
  if (stamps.length === 0) return null
  return stamps.reduce((latest, at) => (Date.parse(at) > Date.parse(latest) ? at : latest))
}

function startedAt(build: DbtBuildRow): string | null {
  return build.started_at ?? build.scheduled_time
}

function Row({ build, now }: { build: DbtBuildRow; now: string | null }) {
  const { search } = useSportFilter()
  const failed = (build.n_failed_queries ?? 0) > 0
  const at = startedAt(build)

  return (
    <tr>
      <td>
        <DbtStateChip state={build.state} />
      </td>
      <td>{build.sport}</td>
      <td>
        {build.build_id ? (
          <Link className="pipe-link" to={{ pathname: `/dbt/builds/${build.build_id}`, search }}>
            {build.args}
          </Link>
        ) : (
          // No BUILD_ID means the task never reached EXECUTE DBT PROJECT, so
          // there is no detail page to open: the error message is the whole
          // record, and it is carried here rather than dropped.
          <span className="nobuild" title={build.error_message ?? 'no BUILD_ID recorded'}>
            {build.args} <em>no BUILD_ID</em>
          </span>
        )}
      </td>
      <td className="num">{build.drained_loads == null ? '·' : num(build.drained_loads)}</td>
      <td className="num">{duration(build.duration_s) ?? '·'}</td>
      <td className="num">
        {build.n_queries == null ? (
          '·'
        ) : (
          <>
            {num(build.n_queries)}
            {failed ? <b className="fail"> · {num(build.n_failed_queries)} failed</b> : null}
          </>
        )}
      </td>
      <td className="num">{build.max_elapsed_ms == null ? '·' : elapsedMs(build.max_elapsed_ms)}</td>
      <td>{at && now ? relativeTo(at, now) : '·'}</td>
    </tr>
  )
}

export default function DbtBuilds() {
  const { sport } = useSportFilter()
  const [payload, setPayload] = useState<DbtBuildsPayload | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    setPayload(null)
    setError(null)
    fetchDbtBuilds(sport, BUILD_LIMIT, controller.signal)
      .then(setPayload)
      .catch((err: unknown) => {
        if (!isAbort(err)) setError(err instanceof Error ? err.message : String(err))
      })
    return () => controller.abort()
  }, [sport])

  const now = payload ? reference(payload.builds) : null

  return (
    <>
      <TopBar meta={payload ? `${payload.builds.length} builds · newest first` : null} />
      <main className="wrap">
        <h1>dbt builds</h1>
        <p className="subtitle">
          Prod dbt runs when data lands, not when code is pushed: each row is one firing of
          DBT_BUILD_&lt;SPORT&gt;, the triggered task that drains the RAW._DLT_LOADS stream and calls
          EXECUTE DBT PROJECT. These tasks are invisible to V_TASK_RUNS by design, so this page is
          the only place they surface.
        </p>
        {error && <p className="load-error">{error}</p>}
        {!payload && !error && <p className="loading">Loading dbt builds...</p>}
        {payload && payload.builds.length === 0 && (
          <p className="loading">No dbt builds recorded for this filter.</p>
        )}
        {payload && payload.builds.length > 0 && (
          <>
            <SectionHead
              title="Recent builds"
              count={`${payload.builds.length} builds · one row per DBT_BUILD task run`}
            />
            <div className="table-scroll">
              <table className="pipes-table dbt-table">
                <thead>
                  <tr>
                    <th>State</th>
                    <th>Sport</th>
                    <th>Args</th>
                    <th className="num">DRAINED_LOADS</th>
                    <th className="num">DURATION_S</th>
                    <th className="num">Queries</th>
                    <th className="num">MAX_ELAPSED_MS</th>
                    <th>Started</th>
                  </tr>
                </thead>
                <tbody>
                  {payload.builds.map((build) => (
                    <Row key={build.run_query_id} build={build} now={now} />
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </main>
    </>
  )
}
