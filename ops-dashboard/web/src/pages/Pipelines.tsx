import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { fetchPipelinesIndex } from '../api/client.ts'
import type { PipelineIndexRow, PipelinesIndexPayload } from '../api/types.ts'
import { SectionHead } from '../components/SectionHead.tsx'
import { TopBar } from '../components/TopBar.tsx'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { dayHhmm, num } from '../utils/format.ts'

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function relative(at: string, now: string): string {
  const minutes = Math.max(0, Math.round((Date.parse(now) - Date.parse(at)) / 60000))
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h ago`
  const days = Math.floor(hours / 24)
  return days === 1 ? 'yesterday' : `${days} days ago`
}

function Row({ row, now }: { row: PipelineIndexRow; now: string }) {
  const { search } = useSportFilter()
  const latest = row.latest
  return (
    <tr>
      <td>
        <Link
          className="pipe-link"
          to={{ pathname: `/pipelines/${row.sport}/${row.pipeline}`, search }}
        >
          {row.pipeline}
        </Link>
      </td>
      <td>{row.schedule}</td>
      <td>
        {latest ? (
          <Link className="last-run" to={`/runs/${latest.query_id}`}>
            <span className={`st st-${latest.state} cell-box`} />
            {latest.state} · {relative(latest.at, now)}
          </Link>
        ) : (
          <span className="muted">never ran</span>
        )}
      </td>
      <td className="num">{latest?.duration_s != null ? `${latest.duration_s}s` : '·'}</td>
      <td className="num">{latest?.rows_loaded != null ? num(latest.rows_loaded) : '·'}</td>
      <td className="num">
        {row.runs_in_window > 0 ? `${row.succeeded} / ${row.runs_in_window}` : '·'}
      </td>
      <td>{dayHhmm(row.next_fire)} UTC</td>
    </tr>
  )
}

export default function Pipelines() {
  const { sport } = useSportFilter()
  const [payload, setPayload] = useState<PipelinesIndexPayload | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    setPayload(null)
    setError(null)
    fetchPipelinesIndex(sport, controller.signal)
      .then(setPayload)
      .catch((err: unknown) => {
        if (!isAbort(err)) setError(err instanceof Error ? err.message : String(err))
      })
    return () => controller.abort()
  }, [sport])

  const sports = payload ? [...new Set(payload.pipelines.map((p) => p.sport))].sort() : []

  return (
    <>
      <TopBar
        meta={payload ? `${payload.pipelines.length} pipelines · last ${payload.window_days} days` : null}
      />
      <main className="wrap">
        <h1>Pipelines</h1>
        <p className="subtitle">
          Every registered pipeline, including ones that never ran. Sport list and schedules
          come from DLT_DB.OPS.PIPELINE_REGISTRY.
        </p>
        {error && <p className="load-error">{error}</p>}
        {!payload && !error && <p className="loading">Loading pipelines...</p>}
        {payload &&
          sports.map((sportName) => (
            <section key={sportName}>
              <SectionHead
                title={sportName}
                count={`${payload.pipelines.filter((p) => p.sport === sportName).length} pipelines`}
              />
              <table className="pipes-table">
                <thead>
                  <tr>
                    <th>Pipeline</th>
                    <th>Schedule</th>
                    <th>Last run</th>
                    <th className="num">DURATION_S</th>
                    <th className="num">ROWS_LOADED</th>
                    <th className="num">Succeeded · {payload.window_days}d</th>
                    <th>Next fire</th>
                  </tr>
                </thead>
                <tbody>
                  {payload.pipelines
                    .filter((p) => p.sport === sportName)
                    .map((row) => (
                      <Row key={row.pipeline} row={row} now={payload.now} />
                    ))}
                </tbody>
              </table>
            </section>
          ))}
      </main>
    </>
  )
}
