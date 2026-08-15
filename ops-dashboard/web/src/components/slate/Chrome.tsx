import { NavLink } from 'react-router-dom'
import type { SlateDay } from '../../api/types.ts'
import { useOpsSearch } from '../../hooks/useDayParam.ts'
import { hhmm } from '../../utils/format.ts'

interface ChromeProps {
  /** The payload's clock, never the browser's: a stale tab must not age itself. */
  now?: string
  /** Omitted on pages that are not day-scoped, which hides the strip entirely. */
  days?: SlateDay[]
  selected?: string
  onSelect?: (date: string) => void
}

function linkClass({ isActive }: { isActive: boolean }): string {
  return isActive ? 'on' : ''
}

/** What a day tab says under its date.

    A day still ahead has nothing to report but its size, so it counts slots. A
    day with anything wrong leads with the damage and only then mentions what is
    still to come. Everything else is the quiet case. */
function tally(day: SlateDay): { text: string; bad: boolean } {
  const bad = day.failed + day.missed
  if (day.ran === 0 && bad === 0 && day.upcoming > 0) {
    return { text: `${day.slots} slots`, bad: false }
  }
  if (bad > 0) {
    const left = day.upcoming > 0 ? ` · ${day.upcoming} left` : ''
    return { text: `${bad} failed${left}`, bad: true }
  }
  return { text: `${day.ran} ran`, bad: false }
}

export function Chrome({ now, days, selected, onSelect }: ChromeProps) {
  const search = useOpsSearch()

  return (
    <>
      <header className="sl-chrome">
        <span className="sl-wordmark">
          weekend-warriors <span className="dim">/ ops</span>
        </span>
        <nav className="sl-nav">
          <NavLink to={{ pathname: '/', search }} end className={linkClass}>
            Dashboard
          </NavLink>
          <NavLink to={{ pathname: '/ingestion', search }} className={linkClass}>
            Pipelines
          </NavLink>
          <NavLink to={{ pathname: '/dbt', search }} className={linkClass}>
            Builds
          </NavLink>
        </nav>
        <span className="sl-spacer" />
        {now ? (
          <span className="sl-fresh">
            <span className="live" />
            refreshed {hhmm(now)} UTC · event-driven
          </span>
        ) : null}
      </header>

      {days && days.length > 0 ? (
        <div className="sl-daystrip">
          {days.map((day) => {
            const { text, bad } = tally(day)
            const classes = ['sl-tab']
            if (day.date === selected) classes.push('on')
            if (day.is_today) classes.push('today')
            return (
              <button
                key={day.date}
                type="button"
                className={classes.join(' ')}
                onClick={() => onSelect?.(day.date)}
              >
                <span className="dow">{day.dow}</span>
                <span className="dnum">{day.date.slice(5)}</span>
                <span className={bad ? 'tally bad' : 'tally'}>{text}</span>
              </button>
            )
          })}
        </div>
      ) : null}
    </>
  )
}
