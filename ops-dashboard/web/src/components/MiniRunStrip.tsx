import type { SlotSample } from '../api/types.ts'
import { hhmm, weekday } from '../utils/format.ts'

const KNOWN_STATES = new Set(['succeeded', 'failure', 'missing', 'missed', 'upcoming'])

const GLYPHS: Record<string, string> = {
  succeeded: '✓',
  failure: '✗',
  missing: '▣',
  missed: '!',
  upcoming: '·',
}

const STATE_WORDS: Record<string, string> = {
  succeeded: 'SUCCEEDED',
  failure: 'FAILED',
  missing: 'FAILED, DLT_RECORD_MISSING',
  missed: 'cron slot passed, no run row',
  upcoming: 'scheduled, not yet fired',
}

function stateClass(state: string): string {
  return KNOWN_STATES.has(state) ? state : 'unknown'
}

interface Props {
  slots: SlotSample[]
  /** Outlines the box for this timestamp, for pages rendering one run in the
      context of its neighbours. */
  currentAt?: string
  /** Trailing dashed box standing for the slot that produced no run row; it has
      no timestamp of its own in `slots` because no row exists. */
  trailingMissed?: boolean
  caption?: string
}

export function MiniRunStrip({ slots, currentAt, trailingMissed, caption }: Props) {
  return (
    <div className="slotstrip">
      {slots.map((slot) => {
        const known = stateClass(slot.state)
        const classes = ['slot', 'st', `st-${known}`]
        if (currentAt && slot.at === currentAt) classes.push('cur')
        return (
          <span
            key={`${slot.at}-${slot.state}`}
            className={classes.join(' ')}
            title={`${weekday(slot.at)} ${hhmm(slot.at)} ${STATE_WORDS[known] ?? slot.state}`}
          >
            {GLYPHS[known] ?? '·'}
          </span>
        )
      })}
      {trailingMissed ? (
        <span className="slot st st-missed" title="this slot passed, no run row">
          !
        </span>
      ) : null}
      {caption ? <span className="cap">{caption}</span> : null}
    </div>
  )
}
