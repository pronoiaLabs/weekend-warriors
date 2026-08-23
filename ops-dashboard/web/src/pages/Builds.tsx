import { useNavigate } from 'react-router-dom'
import { fetchDbtBuilds } from '../api/client.ts'
import type { DbtBuildRow } from '../api/types.ts'
import { DbtStateChip } from '../components/DbtStateChip.tsx'
import TileFrame from '../components/TileFrame.tsx'
import { useApi } from '../hooks/useApi.ts'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { duration, elapsedMs, num, relativeTo } from '../utils/format.ts'
import { leagueLabel } from '../utils/leagues.ts'
import '../styles/pages/builds.css'

const BUILD_LIMIT = 50
// A sport whose newest build is older than this has stopped building, which for
// a seasonal sport is the normal off-season state rather than a fault.
const PAUSED_DAYS = 14
const DAY_MS = 86_400_000
// The placeholder for a value the build never recorded.
const NONE = '·'

/** The payload carries no `now`, so the newest thing it describes stands in for
    one: the browser clock would age a stale tab all by itself. This is also why
    the page never calls setNow, since it has no clock of the API's to publish. */
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

/** Median rather than mean for the headline duration: one 40-minute backfill
    would drag an average away from what a build normally costs. */
function median(values: number[]): number | null {
  if (values.length === 0) return null
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
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

/** One sport's latest build as a KPI plate: how long it took, what it ran, and
    whether the sport is building at all. */
function Roll({ roll }: { roll: Rollup }) {
  return (
    <div className={`kpi ${roll.paused ? 'paused' : ''}`}>
      <span className="l">{leagueLabel(roll.sport)}</span>
      <span className="v">
        {roll.newest.duration_s == null ? NONE : `${roll.newest.duration_s}s`}
      </span>
      <span className="s">
        last build · {roll.newest.args} · {rollupLabel(roll)}
      </span>
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
  const classes = [failed(build) ? 'fail' : '', to ? 'row-link' : ''].filter(Boolean).join(' ')

  return (
    <tr className={classes} onClick={to ? () => navigate({ pathname: to, search }) : undefined}>
      <td className="pname">{build.sport}</td>
      <td>
        <DbtStateChip state={build.state} />
      </td>
      <td className="args" title={build.error_message ?? undefined}>
        {build.args}
        {to ? null : <em> no BUILD_ID</em>}
      </td>
      <td className="num">{build.drained_loads == null ? NONE : num(build.drained_loads)}</td>
      <td className="num">{duration(build.duration_s) ?? NONE}</td>
      <td className="num">{build.n_queries == null ? NONE : num(build.n_queries)}</td>
      <td className={(build.n_failed_queries ?? 0) > 0 ? 'num bad' : 'num'}>
        {build.n_failed_queries == null ? NONE : num(build.n_failed_queries)}
      </td>
      <td className="num">{build.max_elapsed_ms == null ? NONE : elapsedMs(build.max_elapsed_ms)}</td>
      <td className="num">{at && now ? relativeTo(at, now) : NONE}</td>
    </tr>
  )
}

/** The dbt builds as a box score: the window's totals, a rollup per sport that
    answers whether builds are healthy, then the build-by-build log underneath. */
export default function Builds() {
  const { sport } = useSportFilter()
  const builds = useApi((signal) => fetchDbtBuilds(sport, BUILD_LIMIT, signal), [sport])

  const rows = builds.data?.builds ?? []
  const now = reference(rows)
  const rolls = rollups(rows, now)

  return (
    <div className="page page-builds">
      <div className="page-head">
        <h1>Builds</h1>
        <p className="lede">
          {builds.data
            ? `A dbt build fires when data lands, not on a schedule: a successful dlt load drains the trigger stream and the triggered task runs the sport's project. The last ${rows.length} for ${sport === 'all' ? 'every sport' : sport}, newest first.`
            : builds.error
              ? builds.error
              : 'Loading the builds...'}
        </p>
      </div>

      {rows.length > 0 && <Kpis rows={rows} sport={sport} />}

      {rolls.length > 0 && (
        <div className="rolls">
          {rolls.map((roll) => (
            <Roll key={roll.sport} roll={roll} />
          ))}
        </div>
      )}

      {builds.error && (
        <section className="tile">
          <header className="tile-head">
            <h2>Could not load the builds</h2>
          </header>
          <p className="hint">{builds.error}</p>
        </section>
      )}

      {builds.data && rows.length === 0 && (
        <TileFrame title="No build in the window" meta={sport === 'all' ? 'all sports' : sport}>
          <p className="hint">No dbt build recorded for this sport filter.</p>
        </TileFrame>
      )}

      {rows.length > 0 && (
        <TileFrame
          title="Build log"
          meta="newest first"
          className="table-tile"
          query={builds.data?.query}
          caption="A row with no BUILD_ID died before EXECUTE DBT PROJECT and has no detail page; hover the args for the error."
        >
          <table className="standings">
            <thead>
              <tr>
                <th>Sport</th>
                <th>State</th>
                <th>Args</th>
                <th className="num">Drained</th>
                <th className="num">Duration</th>
                <th className="num">Queries</th>
                <th className="num">Failed</th>
                <th className="num">Slowest</th>
                <th className="num">Started</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((build) => (
                <Row key={build.run_query_id} build={build} now={now} />
              ))}
            </tbody>
          </table>
        </TileFrame>
      )}
    </div>
  )
}

function Kpis({ rows, sport }: { rows: DbtBuildRow[]; sport: string }) {
  const bad = rows.filter(failed).length
  const mid = median(rows.map((b) => b.duration_s).filter((v): v is number => v != null))
  const queries = rows.reduce((sum, b) => sum + (b.n_queries ?? 0), 0)
  const drained = rows.reduce((sum, b) => sum + (b.drained_loads ?? 0), 0)

  return (
    <div className="kpis four">
      <div className="kpi">
        <span className="l">Builds</span>
        <span className="v">{rows.length}</span>
        <span className="s">in the window, {sport === 'all' ? 'all sports' : sport}</span>
      </div>
      <div className={`kpi ${bad ? 'bad' : 'good'}`}>
        <span className="l">Failed</span>
        <span className="v">{bad}</span>
        <span className="s">{bad ? 'did not reach SUCCEEDED' : 'every build succeeded'}</span>
      </div>
      <div className="kpi">
        <span className="l">Median build</span>
        <span className="v">{mid == null ? NONE : (duration(Math.round(mid)) ?? NONE)}</span>
        <span className="s">{num(queries)} queries across the window</span>
      </div>
      <div className="kpi">
        <span className="l">Loads drained</span>
        <span className="v">{num(drained)}</span>
        <span className="s">dlt loads the trigger stream carried in</span>
      </div>
    </div>
  )
}
