import { Link } from 'react-router-dom'
import type { PipelineIndexRow } from '../../api/types.ts'
import { useOpsSearch } from '../../hooks/useDayParam.ts'
import { pctText, streakClass } from '../../utils/records.ts'
import TileFrame from '../TileFrame.tsx'

// The rail is a teaser for the full table, so it carries the reason to click:
// the worst six records, nothing else.
const SHOWN = 6
// Under this, a pipeline is losing often enough to be worth a rose number.
const LOW_PCT = 0.6

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

export function RecordsPanel({ rows }: { rows: PipelineIndexRow[] }) {
  const search = useOpsSearch()
  const shown = worstFirst(rows).slice(0, SHOWN)
  return (
    <TileFrame
      title="Records"
      meta="last 14 runs"
      caption={
        <Link to={{ pathname: '/pipelines', search }} className="more">
          full records →
        </Link>
      }
    >
      {shown.length > 0 ? (
        <table className="standings">
          <thead>
            <tr>
              <th>Pipeline</th>
              <th className="rec">W-L</th>
              <th className="pct">Pct</th>
              <th className="strk">Strk</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((row) => (
              <tr key={`${row.sport}:${row.pipeline}`}>
                <td className="pname">
                  <Link to={{ pathname: `/ingestion/${encodeURIComponent(row.sport)}/${encodeURIComponent(row.pipeline)}`, search }}>{row.pipeline}</Link>
                </td>
                <td className="rec">
                  {row.record?.wins ?? 0}-{row.record?.losses ?? 0}
                </td>
                <td className={row.record?.pct != null && row.record.pct < LOW_PCT ? 'pct low' : 'pct'}>{pctText(row.record?.pct)}</td>
                <td className={streakClass(row.record?.streak)}>{row.record?.streak ?? '·'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <p className="hint">no records yet</p>
      )}
    </TileFrame>
  )
}
