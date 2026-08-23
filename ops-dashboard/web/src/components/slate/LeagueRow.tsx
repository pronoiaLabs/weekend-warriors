import { useRef } from 'react'
import type { SlateLeague } from '../../api/types.ts'
import { leagueLabel } from '../../utils/leagues.ts'
import { num } from '../../utils/format.ts'
import TileFrame from '../TileFrame.tsx'
import { ScoreCard } from './ScoreCard.tsx'

// One card plus one gap, so an arrow press lands the next card at the same edge.
const STEP = 262

function subtitle(league: SlateLeague, filtered: boolean): string {
  const shown = league.cards.length
  if (league.kind === 'dbt') {
    if (filtered) return `${shown} build${shown === 1 ? '' : 's'} matching the filter`
    return 'fired by data landing, not by schedule'
  }
  const slots = league.slots ?? 0
  if (filtered) return `${shown} of ${slots} slot${slots === 1 ? '' : 's'} · ${num(league.rows_loaded)} rows in`
  return `${slots} slot${slots === 1 ? '' : 's'} today · ${num(league.rows_loaded)} rows in`
}

/** One league's slate: a tile whose body is a horizontal rail of score cards.
    The rail scrolls natively, so the arrows are a convenience over scroll-snap
    rather than the only way through. `filtered` is set when the page chips
    have dropped cards, so the subtitle does not claim the full day's slots. */
export function LeagueRow({ league, filtered = false }: { league: SlateLeague; filtered?: boolean }) {
  const cards = useRef<HTMLDivElement>(null)
  const scrollBy = (offset: number) => cards.current?.scrollBy({ left: offset, behavior: 'smooth' })
  const label = leagueLabel(league.sport)
  return (
    <TileFrame
      className="league"
      title={
        <>
          {label}
          <span className="car-nav">
            <button type="button" onClick={() => scrollBy(-STEP)} aria-label={`Scroll ${label} back`}>
              ‹
            </button>
            <button type="button" onClick={() => scrollBy(STEP)} aria-label={`Scroll ${label} forward`}>
              ›
            </button>
          </span>
        </>
      }
      meta={subtitle(league, filtered)}
    >
      <div className="cards" ref={cards}>
        {league.cards.map((card) => (
          <ScoreCard key={`${card.kind}:${card.kind === 'build' ? card.build_id : card.pipeline}:${card.at}`} card={card} sport={league.sport} />
        ))}
      </div>
    </TileFrame>
  )
}
