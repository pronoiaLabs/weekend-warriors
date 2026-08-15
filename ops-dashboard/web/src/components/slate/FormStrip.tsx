import { Link } from 'react-router-dom'
import type { FormCell } from '../../api/types.ts'
import { useOpsSearch } from '../../hooks/useDayParam.ts'

/** The strip is always the same width so the column reads as a column. A
    pipeline with a shorter history is padded on the LEFT, which keeps the most
    recent cell at the right edge for every row: the eye compares last runs by
    scanning down one line rather than hunting for where each strip ends. */
const CELLS = 14

interface FormStripProps {
  /** Chronological, oldest first, as the API emits it. */
  form: FormCell[]
}

/** Last-14 form as a heartbeat strip: a win, a loss, or a slot that fired
    nothing. A cell with a run behind it opens that run; a missed slot has no
    query to open, so it stays inert. */
export function FormStrip({ form }: FormStripProps) {
  const search = useOpsSearch()
  const shown = form.slice(-CELLS)
  const pad = CELLS - shown.length

  return (
    <span className="sl-form">
      {Array.from({ length: pad }, (_, index) => (
        <i key={`pad-${index}`} />
      ))}
      {shown.map((cell, index) => {
        const label = `${cell.at.slice(0, 10)} ${cell.result}`
        const kind = cell.result.toLowerCase()
        if (!cell.query_id) return <i key={`${cell.at}-${index}`} className={kind} title={label} />
        return (
          <Link
            key={`${cell.at}-${index}`}
            className={kind}
            title={label}
            aria-label={label}
            to={{ pathname: `/runs/${encodeURIComponent(cell.query_id)}`, search }}
            // The strip sits inside a row that navigates on click, so a cell has
            // to claim its own click or the row would win the race back.
            onClick={(event) => event.stopPropagation()}
          />
        )
      })}
    </span>
  )
}
