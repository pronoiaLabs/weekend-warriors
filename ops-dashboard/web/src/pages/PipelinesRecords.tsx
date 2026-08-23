import { useEffect } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { fetchPipelinesIndex } from '../api/client.ts'
import type { PipelineIndexRow, PipelinesIndexPayload } from '../api/types.ts'
import { FormStrip } from '../components/slate/FormStrip.tsx'
import { pctText, streakClass } from '../utils/records.ts'
import TileFrame from '../components/TileFrame.tsx'
import { useApi } from '../hooks/useApi.ts'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import { ALL_SPORTS, useSportFilter } from '../hooks/useSportFilter.ts'
import { useChrome } from '../state/chrome.tsx'
import { compact, dayHhmm, duration, num, relativeTo } from '../utils/format.ts'
import { leagueLabel } from '../utils/leagues.ts'
import '../styles/pages/pipelines.css'

// Under this, a pipeline is losing often enough to be worth a rose number.
// The same threshold the rail's RecordsPanel uses.
const LOW_PCT = 0.6
// Pipeline, Form, W-L, Pct, Strk, Last run, Rows last, Avg dur, Next slot.
const COLUMNS = 9
// The placeholder for a number the window never produced. A middle dot, so it
// cannot be read as a zero.
const NONE = '·'

interface League {
  sport: string
  rows: PipelineIndexRow[]
}

/** Worst first inside a league. A pipeline the window never decided sorts last,
    because no record is not the same as a bad one; losses break a tie at equal
    pct, so 3-9 leads 1-3; the name settles the rest so the order never churns
    between loads. */
function worstFirst(rows: PipelineIndexRow[]): PipelineIndexRow[] {
  return [...rows].sort((left, right) => {
    const a = left.record?.pct
    const b = right.record?.pct
    if (a == null && b != null) return 1
    if (a != null && b == null) return -1
    if (a != null && b != null && a !== b) return a - b
    const losses = (right.record?.losses ?? 0) - (left.record?.losses ?? 0)
    if (losses !== 0) return losses
    return left.pipeline.localeCompare(right.pipeline)
  })
}

/** Leagues in the order the payload first mentions them, which is the registry's
    order: a sport added tomorrow lands where the API puts it rather than being
    re-alphabetised here. */
function leagues(rows: PipelineIndexRow[]): League[] {
  const order: string[] = []
  const bySport = new Map<string, PipelineIndexRow[]>()
  for (const row of rows) {
    const held = bySport.get(row.sport)
    if (held) {
      held.push(row)
    } else {
      order.push(row.sport)
      bySport.set(row.sport, [row])
    }
  }
  return order.map((sport) => ({ sport, rows: worstFirst(bySport.get(sport) ?? []) }))
}

function lastRun(row: PipelineIndexRow, now: string): string {
  if (!row.latest) return 'never'
  return `${row.latest.state} · ${relativeTo(row.latest.at, now)}`
}

/** Every pipeline as one standings table: the season view behind the slate's
    Records rail, grouped by league and sorted so the reason to visit is always
    at the top of its group. */
export default function PipelinesRecords() {
  const { sport } = useSportFilter()
  const { setNow } = useChrome()
  const index = useApi((signal) => fetchPipelinesIndex(sport, signal), [sport])

  useEffect(() => {
    setNow(index.data?.now ?? null)
    return () => setNow(null)
  }, [index.data?.now, setNow])

  const data = index.data
  const grouped = data ? leagues(data.pipelines) : []

  return (
    <div className="page page-pipelines">
      <div className="page-head">
        <h1>Pipelines</h1>
        <p className="lede">
          {data
            ? `Every pipeline as one standings table, the last ${data.window_days} days${sport === ALL_SPORTS ? ', all sports' : `, ${sport}`}. A win is a run the window decided in the pipeline's favour, a loss one it did not, and a missed slot sits in the form strip without touching the record.`
            : index.error
              ? index.error
              : 'Loading the records...'}
        </p>
      </div>

      {data && <Kpis data={data} />}

      <div className="filters">
        <span className="hint">
          Worst record first inside each league. Click a row for the pipeline, a form cell for that
          run.
        </span>
      </div>

      {index.error && !data && (
        <section className="tile">
          <header className="tile-head">
            <h2>Could not load the records</h2>
          </header>
          <p className="hint">{index.error}</p>
        </section>
      )}

      {data && (
        <TileFrame
          title="Records"
          meta={`${data.pipelines.length} pipelines · last ${data.window_days} days`}
          className="table-tile"
          query={data.query}
        >
          {grouped.length > 0 ? (
            <table className="standings">
              <thead>
                <tr>
                  <th>Pipeline</th>
                  <th>Form</th>
                  <th className="rec">W-L</th>
                  <th className="pct">Pct</th>
                  <th className="strk">Strk</th>
                  <th>Last run</th>
                  <th className="num">Rows last</th>
                  <th className="num">Avg dur</th>
                  <th>Next slot</th>
                </tr>
              </thead>
              <tbody>
                {grouped.map((league) => (
                  <LeagueBlock key={league.sport} league={league} now={data.now} />
                ))}
              </tbody>
            </table>
          ) : (
            <p className="hint">No pipeline matches this sport filter.</p>
          )}
        </TileFrame>
      )}
    </div>
  )
}

/** The window read as one line: how many pipelines there are, how many are
    winning, how many are losing, and what the window cost in missed slots. Every
    number is derived from the rows, so the KPIs and the table can never
    disagree. */
function Kpis({ data }: { data: PipelinesIndexPayload }) {
  const rows = data.pipelines
  // A pipeline the window never decided counts as neither healthy nor losing:
  // no record is not the same as a bad one.
  const healthy = rows.filter((r) => r.record?.pct != null && r.record.pct >= LOW_PCT).length
  const losing = rows.filter((r) => r.record?.pct != null && r.record.pct < LOW_PCT).length
  const missed = rows.reduce((n, r) => n + r.form.filter((c) => c.result === 'M').length, 0)
  const rowsIn = rows.reduce((n, r) => n + (r.latest?.rows_loaded ?? 0), 0)

  return (
    <div className="kpis five">
      <div className="kpi">
        <span className="l">Pipelines</span>
        <span className="v">{rows.length}</span>
        <span className="s">on the schedule</span>
      </div>
      <div className={`kpi ${healthy ? 'good' : ''}`}>
        <span className="l">Healthy</span>
        <span className="v">{healthy}</span>
        <span className="s">pct at {LOW_PCT.toFixed(3)} or better</span>
      </div>
      <div className={`kpi ${losing ? 'bad' : 'good'}`}>
        <span className="l">Losing</span>
        <span className="v">{losing}</span>
        <span className="s">pct under {LOW_PCT.toFixed(3)}</span>
      </div>
      <div className={`kpi ${missed ? 'warn' : ''}`}>
        <span className="l">Missed slots</span>
        <span className="v">{missed}</span>
        <span className="s">cron slots that never fired</span>
      </div>
      <div className="kpi">
        <span className="l">Rows in</span>
        <span className="v">{compact(rowsIn)}</span>
        <span className="s">{num(rowsIn)} rows across each pipeline's latest run</span>
      </div>
    </div>
  )
}

/** One league's block: a divider row that names it, then its pipelines. Kept a
    component so the table body stays a flat list of them. */
function LeagueBlock({ league, now }: { league: League; now: string }) {
  return (
    <>
      <tr className="divider">
        <td colSpan={COLUMNS}>{leagueLabel(league.sport)}</td>
      </tr>
      {league.rows.map((row) => (
        <Row key={`${row.sport}:${row.pipeline}`} row={row} now={now} />
      ))}
    </>
  )
}

function Row({ row, now }: { row: PipelineIndexRow; now: string }) {
  const navigate = useNavigate()
  const search = useOpsSearch()
  const to = `/ingestion/${encodeURIComponent(row.sport)}/${encodeURIComponent(row.pipeline)}`
  const record = row.record

  return (
    <tr className="row-link" onClick={() => navigate({ pathname: to, search })}>
      <td className="pname">
        {/* The whole row navigates, but the name stays a real link so the page
            is reachable by keyboard and can be opened in a new tab. */}
        <Link to={{ pathname: to, search }} onClick={(event) => event.stopPropagation()}>
          {row.pipeline}
        </Link>
      </td>
      <td>
        <FormStrip form={row.form} />
      </td>
      <td className="rec">
        {record?.wins ?? 0}-{record?.losses ?? 0}
      </td>
      <td className={record?.pct != null && record.pct < LOW_PCT ? 'pct low' : 'pct'}>
        {pctText(record?.pct)}
      </td>
      <td className={streakClass(record?.streak)}>{record?.streak ?? NONE}</td>
      <td>{lastRun(row, now)}</td>
      <td className="num">{row.latest?.rows_loaded != null ? num(row.latest.rows_loaded) : NONE}</td>
      <td className="num">{duration(row.avg_duration_s) ?? NONE}</td>
      <td>{dayHhmm(row.next_fire)}</td>
    </tr>
  )
}
