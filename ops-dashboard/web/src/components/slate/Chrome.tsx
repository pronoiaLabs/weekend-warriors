import { useEffect, useState } from 'react'
import { NavLink } from 'react-router-dom'
import { fetchSports } from '../../api/client.ts'
import type { SlateDay } from '../../api/types.ts'
import { useOpsSearch } from '../../hooks/useDayParam.ts'
import { ALL_SPORTS, useSportFilter } from '../../hooks/useSportFilter.ts'
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

/** The strip's reference day: the explicit selection, else its center. */
function anchor(days: SlateDay[], selected?: string): string {
  return selected ?? days[Math.floor(days.length / 2)].date
}

/** ISO date arithmetic in UTC. `toToday` asks for the browser's UTC today,
    used only when today has scrolled out of the fetched window entirely. */
function shiftDay(iso: string, delta: number, toToday = false): string {
  if (toToday) return new Date().toISOString().slice(0, 10)
  const d = new Date(`${iso}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + delta)
  return d.toISOString().slice(0, 10)
}

/** The global sport filter, made visible.

    The ?sport= param deliberately survives navigation so views stay
    deep-linkable, and an invisible sticky filter is a trap: a dashboard
    quietly scoped to one league reads as missing pipelines. These chips are
    the filter's face on every page, always showing what is active and one
    click from clearing it. */
function SportChips() {
  const { sport, setSport } = useSportFilter()
  const [sports, setSports] = useState<string[]>([])

  useEffect(() => {
    const controller = new AbortController()
    fetchSports(controller.signal)
      .then((payload) => setSports(payload.sports.map((s) => s.sport)))
      .catch(() => setSports([]))
    return () => controller.abort()
  }, [])

  if (sports.length === 0) return null
  return (
    <span className="sl-chips">
      {[ALL_SPORTS, ...sports].map((value) => (
        <button
          key={value}
          type="button"
          className={value === sport ? 'on' : ''}
          onClick={() => setSport(value)}
        >
          {value === ALL_SPORTS ? 'All' : value}
        </button>
      ))}
    </span>
  )
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
          <NavLink to={{ pathname: '/pipelines', search }} className={linkClass}>
            Pipelines
          </NavLink>
          <NavLink to={{ pathname: '/builds', search }} className={linkClass}>
            Builds
          </NavLink>
        </nav>
        <span className="sl-spacer" />
        <SportChips />
        {now ? (
          <span className="sl-fresh">
            <span className="live" />
            refreshed {hhmm(now)} · event-driven
          </span>
        ) : null}
      </header>

      {days && days.length > 0 ? (
        <div className="sl-daystrip">
          <button
            type="button"
            className="sl-daynav"
            title="previous day"
            onClick={() => onSelect?.(shiftDay(anchor(days, selected), -1))}
          >
            &#8249;
          </button>
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
          <button
            type="button"
            className="sl-daynav"
            title="next day"
            onClick={() => onSelect?.(shiftDay(anchor(days, selected), 1))}
          >
            &#8250;
          </button>
          {!days.some((d) => d.is_today && d.date === anchor(days, selected)) ? (
            <button
              type="button"
              className="sl-daynav today"
              onClick={() => {
                const today = days.find((d) => d.is_today)
                onSelect?.(today ? today.date : shiftDay(anchor(days, selected), 0, true))
              }}
            >
              today
            </button>
          ) : null}
        </div>
      ) : null}
    </>
  )
}
