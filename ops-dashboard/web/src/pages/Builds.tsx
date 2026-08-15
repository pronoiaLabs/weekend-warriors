import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { fetchDbtBuilds } from '../api/client.ts'
import type { DbtBuildRow, DbtBuildsPayload } from '../api/types.ts'
import { EmptyState } from '../components/QuietNote.tsx'
import { Chrome } from '../components/slate/Chrome.tsx'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { duration, elapsedMs, num, relativeTo } from '../utils/format.ts'
import { leagueLabel } from '../utils/leagues.ts'

const BUILD_LIMIT = 50
// A sport whose newest build is older than this has stopped building, which for
// a seasonal sport is the normal off-season state rather than a fault.
const PAUSED_DAYS = 14
const DAY_MS = 86_400_000
// The placeholder for a value the build never recorded.
const NONE = '·'

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** The payload carries no `now`, so the newest thing it describes stands in for
    one, the way the dbt builds page does it: the browser clock would age a stale
    tab all by itself. */
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

/** A build that did not reach SUCCEEDED, which includes the ones that died
    before EXECUTE DBT PROJECT and so carry no failed-query count at all. */
function failed(build: DbtBuildRow): boolean {
  return build.state !== 'SUCCEEDED'
}

interface Rollup {
  sport: string
  newest: DbtBuildRow
  /** Mean duration over the fetched builds of this sport, in seconds. */
  avg: number | null
  paused: boolean
}

/** One rollup per sport present in the payload. The list arrives newest first,
    so the first build seen for a sport is that sport's latest. */
function rollups(builds: DbtBuildRow[], now: string | null): Rollup[] {
  const order: string[] = []
  const bySport = new Map<string, DbtBuildRow[]>()
  for (const build of builds) {
    const held = bySport.get(build.sport)
    if (held) {
      held.push(build)
    } else {
      order.push(build.sport)
      bySport.set(build.sport, [build])
    }
  }

  return order.map((sport) => {
    const rows = bySport.get(sport) ?? []
    const newest = rows[0]
    const seconds = rows
      .map((build) => build.duration_s)
      .filter((value): value is number => value != null)
    const at = startedAt(newest)
    const stale =
      now != null && at != null && Date.parse(now) - Date.parse(at) > PAUSED_DAYS * DAY_MS
    return {
      sport,
      newest,
      avg:
        seconds.length > 0 ? seconds.reduce((sum, value) => sum + value, 0) / seconds.length : null,
      paused: stale,
    }
  })
}

function rollupLabel(roll: Rollup): string {
  if (roll.paused) return 'paused · no recent builds'
  const queries = `${num(roll.newest.n_queries)} queries`
  return roll.avg == null ? queries : `${queries} · recent avg ${roll.avg.toFixed(1)}s`
}

function Roll({ roll }: { roll: Rollup }) {
  return (
    <div className={roll.paused ? 'sl-roll paused' : 'sl-roll'}>
      <div className="who">
        {leagueLabel(roll.sport)} · {roll.newest.args}
      </div>
      <div className="big">
        {roll.newest.duration_s == null ? NONE : `${roll.newest.duration_s}s`}
        <span className="of">last</span>
      </div>
      <div className="lbl">{rollupLabel(roll)}</div>
    </div>
  )
}

function Row({ build, now }: { build: DbtBuildRow; now: string | null }) {
  const navigate = useNavigate()
  const search = useOpsSearch()
  // No BUILD_ID means the task never reached EXECUTE DBT PROJECT, so there is no
  // detail page to open and the row stays inert.
  const to = build.build_id ? `/dbt/builds/${encodeURIComponent(build.build_id)}` : null
  const at = startedAt(build)
  const classes = [failed(build) ? 'fail' : '', to ? 'click' : ''].filter(Boolean).join(' ')

  return (
    <tr className={classes} onClick={to ? () => navigate({ pathname: to, search }) : undefined}>
      <td className="pname">{build.sport}</td>
      <td className="misc lt" title={build.error_message ?? undefined}>
        {build.args}
        {to ? null : <em> no BUILD_ID</em>}
      </td>
      <td className="misc">{build.drained_loads == null ? NONE : num(build.drained_loads)}</td>
      <td className="misc">{duration(build.duration_s) ?? NONE}</td>
      <td className="misc">{build.n_queries == null ? NONE : num(build.n_queries)}</td>
      <td className={(build.n_failed_queries ?? 0) > 0 ? 'misc bad' : 'misc'}>
        {build.n_failed_queries == null ? NONE : num(build.n_failed_queries)}
      </td>
      <td className="misc">
        {build.max_elapsed_ms == null ? NONE : elapsedMs(build.max_elapsed_ms)}
      </td>
      <td className="misc">{at && now ? relativeTo(at, now) : NONE}</td>
    </tr>
  )
}

/** The dbt builds as a box score: a rollup per sport that answers whether builds
    are healthy, then the game-by-game log underneath it. */
export default function Builds() {
  const { sport } = useSportFilter()
  const [payload, setPayload] = useState<DbtBuildsPayload | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const control = new AbortController()
    setPayload(null)
    setError(null)
    fetchDbtBuilds(sport, BUILD_LIMIT, control.signal)
      .then(setPayload)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [sport])

  if (error) {
    return (
      <>
        <Chrome />
        <main className="sl-page">
          <EmptyState message="Could not load the builds" detail={error} bad />
        </main>
      </>
    )
  }

  if (!payload) {
    return (
      <>
        <Chrome />
        <main className="sl-page">
          <EmptyState message="Loading the builds" />
        </main>
      </>
    )
  }

  const now = reference(payload.builds)
  const rolls = rollups(payload.builds, now)

  return (
    <>
      <Chrome />
      <main className="sl-page">
        <section className="sl-league">
          <div className="sl-league-head">
            <h2>Builds</h2>
            <span className="sub">dbt builds · fired by data landing, not by schedule</span>
          </div>

          {payload.builds.length === 0 ? (
            <EmptyState message="No dbt build recorded for this sport filter" />
          ) : (
            <>
              <div className="sl-roll-row">
                {rolls.map((roll) => (
                  <Roll key={roll.sport} roll={roll} />
                ))}
              </div>

              <div className="sl-records-wrap">
                <table className="sl-standings">
                  <thead>
                    <tr>
                      <th>Sport</th>
                      <th className="lt">Args</th>
                      <th>Drained</th>
                      <th>Duration</th>
                      <th>Queries</th>
                      <th>Failed</th>
                      <th>Slowest</th>
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
        </section>
      </main>
    </>
  )
}
