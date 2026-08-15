import { useRef } from 'react'
import type { SlateLeague } from '../../api/types.ts'
import { leagueLabel } from '../../utils/leagues.ts'
import { num } from '../../utils/format.ts'
import { ScoreCard } from './ScoreCard.tsx'

// One card plus one gap, so an arrow press lands the next card at the same edge.
const STEP = 262

function subtitle(league: SlateLeague): string {
  if (league.kind === 'dbt') return 'fired by data landing, not by schedule'
  const slots = league.slots ?? 0
  return `${slots} slot${slots === 1 ? '' : 's'} today · ${num(league.rows_loaded)} rows in`
}

interface LeagueRowProps {
  league: SlateLeague
}

/** One league's slate: a heading that reads as a rollup and a horizontal rail of
    score cards. The rail scrolls natively, so the arrows are a convenience over
    scroll-snap rather than the only way through. */
export function LeagueRow({ league }: LeagueRowProps) {
  const cards = useRef<HTMLDivElement>(null)

  function scrollBy(offset: number) {
    cards.current?.scrollBy({ left: offset, behavior: 'smooth' })
  }

  return (
    <section className="sl-league">
      <div className="sl-league-head">
        <h2>{leagueLabel(league.sport)}</h2>
        <span className="sub">{subtitle(league)}</span>
        <span className="sl-car-nav">
          <button
            type="button"
            onClick={() => scrollBy(-STEP)}
            aria-label={`Scroll ${leagueLabel(league.sport)} back`}
          >
            ‹
          </button>
          <button
            type="button"
            onClick={() => scrollBy(STEP)}
            aria-label={`Scroll ${leagueLabel(league.sport)} forward`}
          >
            ›
          </button>
        </span>
      </div>
      <div className="sl-cards" ref={cards}>
        {league.cards.map((card) => (
          <ScoreCard
            key={`${card.kind}:${card.kind === 'build' ? card.build_id : card.pipeline}:${card.at}`}
            card={card}
            sport={league.sport}
          />
        ))}
      </div>
    </section>
  )
}
