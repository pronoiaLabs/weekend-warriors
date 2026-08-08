import { useEffect, useMemo, useState } from 'react'
import { fetchRunLogs } from '../api/client.ts'
import type { LogLine, LogsPayload } from '../api/types.ts'
import { hhmmss, num } from '../utils/format.ts'

const ALL = 'all'
const WARNING_PLUS = 'warning+'
const ERROR_ONLY = 'ERROR'

const CHIPS: { value: string; label: string }[] = [
  { value: ALL, label: 'all' },
  { value: WARNING_PLUS, label: 'WARNING+' },
  { value: ERROR_ONLY, label: 'ERROR' },
]

const AT_LEAST_WARNING = new Set(['WARNING', 'ERROR', 'CRITICAL', 'FATAL'])

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** The constants a run's log lines share, so they are stated once above the
    table rather than repeated down two columns. */
function constants(lines: LogLine[]): string {
  const parts: string[] = []
  for (const [label, key] of [
    ['CONTAINER_NAME', 'container_name'],
    ['LOG_FORMAT', 'log_format'],
  ] as const) {
    const values = [...new Set(lines.map((line) => line[key]).filter(Boolean))]
    if (values.length) parts.push(`${label} ${values.join(', ')}`)
  }
  return parts.join(' · ')
}

interface Props {
  queryId: string
  limit: number
}

export function LogTable({ queryId, limit }: Props) {
  const [severity, setSeverity] = useState(ALL)
  const [payload, setPayload] = useState<LogsPayload | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const control = new AbortController()
    setError(null)
    setPayload(null)
    // Only a single level can be pushed into the query param, because the API
    // matches SEVERITY exactly; WARNING+ therefore fetches the page unfiltered
    // and narrows it here, which the footer says out loud.
    fetchRunLogs(queryId, severity === ERROR_ONLY ? ERROR_ONLY : null, limit, control.signal)
      .then(setPayload)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [queryId, severity, limit])

  const lines = useMemo(() => {
    if (!payload) return []
    if (severity !== WARNING_PLUS) return payload.lines
    return payload.lines.filter((line) => AT_LEAST_WARNING.has(line.severity ?? ''))
  }, [payload, severity])

  return (
    <div className="logs">
      <div className="logchips" role="group" aria-label="Filter log lines by severity">
        <span className="cap">Severity</span>
        {CHIPS.map((chip) => (
          <button
            key={chip.value}
            type="button"
            className={chip.value === severity ? 'chip on' : 'chip'}
            aria-pressed={chip.value === severity}
            onClick={() => setSeverity(chip.value)}
          >
            {chip.label}
          </button>
        ))}
      </div>

      {error ? <p className="pane-src bad">Could not load V_LOG_LINES: {error}</p> : null}
      {!payload && !error ? <p className="pane-src">Loading V_LOG_LINES...</p> : null}

      {payload ? (
        <>
          <div className="pane-src">
            V_LOG_LINES where QUERY_ID = {queryId}
            {constants(payload.lines) ? ` · ${constants(payload.lines)}` : ''}
          </div>
          {lines.length === 0 ? (
            <p className="pane-src">
              No log line matches this filter. LOG_LINES {num(payload.total_log_lines)} on the run
              row.
            </p>
          ) : (
            <table className="logtable">
              <thead>
                <tr>
                  <th>EVENT_TS</th>
                  <th>SEVERITY</th>
                  <th>LOGGER_NAME</th>
                  <th>MESSAGE</th>
                </tr>
              </thead>
              <tbody>
                {lines.map((line, index) => (
                  <tr key={`${line.event_ts}-${index}`}>
                    <td>{hhmmss(line.event_ts)}</td>
                    <td className={`sev-${line.severity ?? 'NONE'}`}>{line.severity ?? 'none'}</td>
                    <td>{line.logger_name ?? 'none'}</td>
                    <td>{line.message}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          <p className="pane-src after">
            {num(lines.length)} of {num(payload.total_log_lines)} lines shown · ERROR_LINES{' '}
            {num(payload.error_lines)} · WARNING_LINES {num(payload.warning_lines)}
            {severity === WARNING_PLUS
              ? ` · WARNING+ narrows the ${num(payload.lines.length)} fetched lines, since the API filters on one exact SEVERITY`
              : ''}
          </p>
        </>
      ) : null}
    </div>
  )
}
