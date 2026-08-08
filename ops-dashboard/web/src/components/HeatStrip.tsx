import { Link } from 'react-router-dom'
import type { HeatCell } from '../api/types.ts'
import { dayShort, longDayTitle } from '../utils/format.ts'

const GLYPHS: Record<string, string> = {
  succeeded: '✓',
  failure: '✗',
  missing: '▣',
  missed: '!',
  scheduled: '',
  none: '',
}

const WORDS: Record<string, string> = {
  succeeded: 'SUCCEEDED',
  failure: 'FAILED',
  missing: 'FAILED, DLT_RECORD_MISSING',
  missed: 'cron slot passed, no run row',
  scheduled: 'scheduled, not yet fired',
  none: 'cron does not fire this day',
}

// `scheduled` and `none` are not run states, so they sit outside the shared .st
// vocabulary: one borrows the dotted upcoming treatment, the other is blank.
const ST_CLASS: Record<string, string> = {
  succeeded: 'st st-succeeded',
  failure: 'st st-failure',
  missing: 'st st-missing',
  missed: 'st st-missed',
  scheduled: 'st st-upcoming',
  none: 'blank',
}

const LEGEND: { state: string; text: string }[] = [
  { state: 'succeeded', text: 'succeeded' },
  { state: 'failure', text: 'failed' },
  { state: 'missing', text: 'DLT_RECORD_MISSING' },
  { state: 'missed', text: 'expected but no run row' },
  { state: 'scheduled', text: 'scheduled, not yet fired' },
  { state: 'none', text: 'cron does not fire' },
]

interface Props {
  cells: HeatCell[]
}

function CellBody({ cell }: { cell: HeatCell }) {
  // The hatched cell needs a solid backing behind its glyph, the same trick the
  // hatched timeline block and verdict box use.
  const glyph = GLYPHS[cell.state] ?? '·'
  return cell.state === 'missing' ? <em>{glyph}</em> : <>{glyph}</>
}

export function HeatStrip({ cells }: Props) {
  // The API builds the strip ending on its own today, so the last cell is today
  // without the browser clock being consulted.
  const todayDate = cells.at(-1)?.date

  return (
    <div className="heatrow">
      {cells.map((cell) => {
        const title = `${longDayTitle(cell.date)} · ${WORDS[cell.state] ?? cell.state}`
        const box = ST_CLASS[cell.state] ?? 'st st-unknown'
        return (
          <div className="hcell" key={cell.date}>
            <div className={cell.date === todayDate ? 'day today' : 'day'}>
              {dayShort(cell.date)}
            </div>
            {cell.query_id ? (
              <Link className={`box ${box}`} to={`/runs/${cell.query_id}`} title={title}>
                <CellBody cell={cell} />
              </Link>
            ) : (
              <div className={`box ${box}`} title={title}>
                <CellBody cell={cell} />
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}

export function HeatLegend() {
  return (
    <div className="heatlegend">
      {LEGEND.map((key) => (
        <span className="key" key={key.state}>
          <span className={`sw ${ST_CLASS[key.state]}`} /> {key.text}
        </span>
      ))}
    </div>
  )
}
