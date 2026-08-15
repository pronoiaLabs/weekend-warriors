import { Link } from 'react-router-dom'
import type { PipelineIndexRow } from '../../api/types.ts'
import { useOpsSearch } from '../../hooks/useDayParam.ts'

// The rail is a teaser for the full table, so it carries the reason to click:
// the worst six records, nothing else.
const SHOWN = 6
// Under this, a pipeline is losing often enough to be worth a red number.
const LOW_PCT = 0.6

interface RecordsPanelProps {
  rows: PipelineIndexRow[]
}

/** Worst first, and a pipeline the window never decided sorts last: no record is
    not the same as a bad one. */
function worstFirst(rows: PipelineIndexRow[]): PipelineIndexRow[] {
  return [...rows].sort((left, right) => {
    const a = left.record?.pct
    const b = right.record?.pct
    if (a == null && b == null) return left.pipeline.localeCompare(right.pipeline)
    if (a == null) return 1
    if (b == null) return -1
    return a - b
  })
}

function pct(value: number | null | undefined): string {
  return value == null ? '·' : value.toFixed(3)
}

function streakClass(streak: string | null | undefined): string {
  if (!streak) return 'strk'
  return streak.startsWith('W') ? 'strk w' : 'strk l'
}

export function RecordsPanel({ rows }: RecordsPanelProps) {
  const search = useOpsSearch()
  const shown = worstFirst(rows).slice(0, SHOWN)

  return (
    <div className="sl-panel">
      <div className="sl-panel-head">
        <h3>Records</h3>
        <span className="sub">last 14 runs</span>
      </div>

      {shown.length > 0 ? (
        <table className="sl-standings">
          <thead>
            <tr>
              <th>Pipeline</th>
              <th>W-L</th>
              <th>Pct</th>
              <th>Strk</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((row) => (
              <tr key={`${row.sport}:${row.pipeline}`}>
                <td className="pname">{row.pipeline}</td>
                <td className="rec">
                  {row.record?.wins ?? 0}-{row.record?.losses ?? 0}
                </td>
                <td
                  className={
                    row.record?.pct != null && row.record.pct < LOW_PCT ? 'pct low' : 'pct'
                  }
                >
                  {pct(row.record?.pct)}
                </td>
                <td className={streakClass(row.record?.streak)}>{row.record?.streak ?? '·'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <p className="sl-empty">no records yet</p>
      )}

      <div className="sl-panel-foot">
        <Link to={{ pathname: '/pipelines', search }}>full records →</Link>
      </div>
    </div>
  )
}
