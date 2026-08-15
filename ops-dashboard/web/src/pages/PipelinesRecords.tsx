import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { fetchPipelinesIndex } from '../api/client.ts'
import type { PipelineIndexRow, PipelinesIndexPayload } from '../api/types.ts'
import { EmptyState } from '../components/QuietNote.tsx'
import { Chrome } from '../components/slate/Chrome.tsx'
import { FormStrip } from '../components/slate/FormStrip.tsx'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { dayHhmm, duration, num, relativeTo } from '../utils/format.ts'
import { leagueLabel } from '../utils/leagues.ts'

// Under this, a pipeline is losing often enough to be worth a red number.
const LOW_PCT = 0.6
// Pipeline, Form, W-L, Pct, Strk, Last run, Rows last, Avg dur, Next slot.
const COLUMNS = 9
// The placeholder for a number the window never produced. A middle dot, so it
// cannot be read as a zero.
const NONE = '·'

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

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

function pct(value: number | null | undefined): string {
  return value == null ? NONE : value.toFixed(3)
}

function streakClass(streak: string | null | undefined): string {
  if (!streak) return 'strk'
  return streak.startsWith('W') ? 'strk w' : 'strk l'
}

function lastRun(row: PipelineIndexRow, now: string): string {
  if (!row.latest) return 'never'
  return `${row.latest.state} · ${relativeTo(row.latest.at, now)}`
}

function Row({ row, now }: { row: PipelineIndexRow; now: string }) {
  const navigate = useNavigate()
  const search = useOpsSearch()
  const to = `/ingestion/${encodeURIComponent(row.sport)}/${encodeURIComponent(row.pipeline)}`
  const record = row.record

  return (
    <tr className="click" onClick={() => navigate({ pathname: to, search })}>
      <td className="pname">
        {/* The whole row navigates, but the name stays a real link so the page
            is reachable by keyboard and can be opened in a new tab. */}
        <Link to={{ pathname: to, search }} onClick={(event) => event.stopPropagation()}>
          {row.pipeline}
        </Link>
      </td>
      <td className="lt">
        <FormStrip form={row.form} />
      </td>
      <td className="rec">
        {record?.wins ?? 0}-{record?.losses ?? 0}
      </td>
      <td className={record?.pct != null && record.pct < LOW_PCT ? 'pct low' : 'pct'}>
        {pct(record?.pct)}
      </td>
      <td className={streakClass(record?.streak)}>{record?.streak ?? NONE}</td>
      <td className="misc">{lastRun(row, now)}</td>
      <td className="misc">
        {row.latest?.rows_loaded != null ? num(row.latest.rows_loaded) : NONE}
      </td>
      <td className="misc">{duration(row.avg_duration_s) ?? NONE}</td>
      <td className="misc">{dayHhmm(row.next_fire)}</td>
    </tr>
  )
}

/** Every pipeline as one standings table: the season view behind the slate's
    Records rail, grouped by league and sorted so the reason to visit is always
    at the top of its group. */
export default function PipelinesRecords() {
  const { sport } = useSportFilter()
  const [payload, setPayload] = useState<PipelinesIndexPayload | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const control = new AbortController()
    setPayload(null)
    setError(null)
    fetchPipelinesIndex(sport, control.signal)
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
          <EmptyState message="Could not load the records" detail={error} bad />
        </main>
      </>
    )
  }

  if (!payload) {
    return (
      <>
        <Chrome />
        <main className="sl-page">
          <EmptyState message="Loading the records" />
        </main>
      </>
    )
  }

  const grouped = leagues(payload.pipelines)

  return (
    <>
      <Chrome now={payload.now} />
      <main className="sl-page">
        <section className="sl-league">
          <div className="sl-league-head">
            <h2>Records</h2>
            <span className="sub">every pipeline · last 14 runs · sorted worst first</span>
          </div>
          {grouped.length > 0 ? (
            <div className="sl-records-wrap">
              <table className="sl-standings">
                <thead>
                  <tr>
                    <th>Pipeline</th>
                    <th className="lt">Form</th>
                    <th>W-L</th>
                    <th>Pct</th>
                    <th>Strk</th>
                    <th>Last run</th>
                    <th>Rows last</th>
                    <th>Avg dur</th>
                    <th>Next slot</th>
                  </tr>
                </thead>
                <tbody>
                  {grouped.map((league) => (
                    <LeagueBlock key={league.sport} league={league} now={payload.now} />
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <EmptyState message="No pipeline matches this sport filter" />
          )}
        </section>
      </main>
    </>
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
