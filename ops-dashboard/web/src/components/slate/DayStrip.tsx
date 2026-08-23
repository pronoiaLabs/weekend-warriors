import { useEffect, useRef } from 'react'
import type { SlateDay } from '../../api/types.ts'

/** One day chip plus one gap, so an arrow press lands the next day at the
    same edge the way LeagueRow's STEP does for score cards. */
const STEP = 64

/** The strip's reference day: the explicit selection, else its centre. */
function anchor(days: SlateDay[], selected?: string): string {
  return selected ?? days[Math.floor(days.length / 2)]!.date
}

/** ISO date arithmetic in UTC. `toToday` asks for the browser's UTC today,
    used only when today has scrolled out of the fetched window entirely. */
function shiftDay(iso: string, delta: number, toToday = false): string {
  if (toToday) return new Date().toISOString().slice(0, 10)
  const d = new Date(`${iso}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + delta)
  return d.toISOString().slice(0, 10)
}

/** What a day chip says under its date. A day still ahead has nothing to report
    but its size, so it counts slots. A day with a failure leads with it in rose;
    a day where slots passed unfired says so in amber; everything else is the
    quiet case. */
function tally(day: SlateDay): { text: string; tone: '' | 'bad' | 'warn' } {
  if (day.ran === 0 && day.failed === 0 && day.missed === 0 && day.upcoming > 0) {
    return { text: `${day.slots} slots`, tone: '' }
  }
  const parts: string[] = []
  if (day.failed > 0) parts.push(`${day.failed} failed`)
  if (day.missed > 0) parts.push(`${day.missed} no show`)
  if (parts.length === 0) return { text: `${day.ran} ran`, tone: '' }
  if (day.upcoming > 0) parts.push(`${day.upcoming} left`)
  return { text: parts.join(' · '), tone: day.failed > 0 ? 'bad' : 'warn' }
}

/** Seven days around the one in view as a vertical carousel: native overflow
    plus snap, arrows as a convenience, click a chip to select. CSS flips it
    to a horizontal scroller under 900px. */
export function DayStrip({ days, selected, onSelect }: { days: SlateDay[]; selected: string; onSelect: (date: string) => void }) {
  const scroller = useRef<HTMLDivElement>(null)
  const selectedRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    selectedRef.current?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }, [selected])

  if (days.length === 0) return null
  const atToday = days.some((d) => d.is_today && d.date === anchor(days, selected))
  const scrollBy = (offset: number) => scroller.current?.scrollBy({ top: offset, left: offset, behavior: 'smooth' })

  return (
    <div className="day-rail-inner">
      <div className="day-rail-head">
        <span className="chip-group-label">Day</span>
        <span className="car-nav">
          <button type="button" onClick={() => scrollBy(-STEP)} aria-label="Scroll days back">
            ‹
          </button>
          <button type="button" onClick={() => scrollBy(STEP)} aria-label="Scroll days forward">
            ›
          </button>
        </span>
        {!atToday && (
          <button
            type="button"
            className="chip nav today-jump"
            onClick={() => {
              const today = days.find((d) => d.is_today)
              onSelect(today ? today.date : shiftDay(anchor(days, selected), 0, true))
            }}
          >
            today
          </button>
        )}
      </div>
      <div className="day-strip rail" role="group" aria-label="Day" ref={scroller}>
        {days.map((day) => {
          const { text, tone } = tally(day)
          const on = day.date === selected
          return (
            <button
              key={day.date}
              ref={on ? selectedRef : undefined}
              type="button"
              className={`chip ${on ? 'on' : ''} ${day.is_today ? 'today' : ''}`}
              aria-pressed={on}
              onClick={() => onSelect(day.date)}
            >
              <span className="dow">{day.dow}</span>
              <span className="dnum">{day.date.slice(5)}</span>
              <span className={`tally ${tone}`}>{text}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}
