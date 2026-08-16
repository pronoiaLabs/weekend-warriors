import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import type { SlateCard } from '../../api/types.ts'
import { useOpsSearch } from '../../hooks/useDayParam.ts'
import { cronProse, duration, hhmm, num } from '../../utils/format.ts'

/** The waiting placeholder, a glyph rather than a number so an upcoming slot
    never reads as a score of zero. Written as an escape so the only em dash in
    the codebase cannot be mistaken for punctuation. */
const WAITING = '\u2014'

interface ScoreCardProps {
  card: SlateCard
  /** The league this card sits in, which is the sport a pipeline link needs. */
  sport: string
}

interface Shell {
  to: string | null
  variant: string
  status: ReactNode
  at: string | null
  team: string
  score: ReactNode
  under: string | null
  meta: string
  err: string | null
}

function prevContext(rows: number | null | undefined): string {
  return rows == null ? '' : ` · previous run: ${num(rows)} rows`
}

function stamp(at: string, seconds: number | null): string {
  const took = duration(seconds)
  return took ? `${hhmm(at)} · ${took}` : hhmm(at)
}

function shell(card: SlateCard, sport: string): Shell {
  if (card.kind === 'build') {
    const failed = card.state === 'failure'
    const loads = card.drained_loads ?? 0
    return {
      to: card.build_id ? `/dbt/builds/${encodeURIComponent(card.build_id)}` : null,
      variant: failed ? 'upset' : '',
      status: <span className={failed ? 'st fail' : 'st final'}>{failed ? 'Failed' : 'Built'}</span>,
      at: stamp(card.at, card.duration_s),
      team: `${card.sport} · ${card.args}`,
      score: (
        <span className="score">
          {num(card.n_queries)}
          <span className="u">queries</span>
        </span>
      ),
      under: `${loads} load${loads === 1 ? '' : 's'} drained`,
      meta: 'triggered',
      err:
        failed && (card.n_failed_queries ?? 0) > 0
          ? `${num(card.n_failed_queries)} queries failed`
          : null,
    }
  }

  const pipelineLink = `/ingestion/${encodeURIComponent(sport)}/${encodeURIComponent(card.pipeline)}`

  if (card.kind === 'missed') {
    return {
      to: pipelineLink,
      variant: 'upset missed',
      status: <span className="st fail">No show</span>,
      at: `${hhmm(card.at)} slot`,
      team: card.pipeline,
      score: <span className="score dash">·</span>,
      under: null,
      meta: cronProse(card.schedule),
      err: 'slot passed, no run row at all',
    }
  }

  if (card.kind === 'upcoming') {
    const last = card.prev
    return {
      to: pipelineLink,
      variant: 'sched',
      status: <span className="st sched">{hhmm(card.at)}</span>,
      at: null,
      team: card.pipeline,
      score: <span className="score dash">{WAITING}</span>,
      under: last
        ? `last: ${num(last.rows_loaded)} rows · ${duration(last.duration_s) ?? 'no duration'}`
        : 'no previous run recorded',
      meta: cronProse(card.schedule),
      err: null,
    }
  }

  const failed = card.state !== 'succeeded'
  return {
    to: card.query_id ? `/runs/${encodeURIComponent(card.query_id)}` : null,
    variant: failed ? 'upset' : '',
    status: (
      <span className={failed ? 'st fail' : 'st final'}>{failed ? 'Failed' : 'Final'}</span>
    ),
    at: stamp(card.at, card.duration_s),
    team: card.pipeline,
    score: (
      <span className="score">
        {num(card.rows_loaded)}
        <span className="u">rows</span>
      </span>
    ),
    under: null,
    meta: cronProse(card.schedule),
    err: failed
      ? `${card.error_excerpt ?? 'no error text recorded'}${prevContext(card.prev?.rows_loaded)}`
      : null,
  }
}

/** One card of the slate. Which of the five shapes it takes is the card kind's
    decision, so the switch lives in one place and the markup stays single. */
export function ScoreCard({ card, sport }: ScoreCardProps) {
  const search = useOpsSearch()
  const parts = shell(card, sport)

  const body = (
    <>
      <div className="status-line">
        {parts.status}
        {parts.at ? <span className="at">{parts.at}</span> : null}
      </div>
      <div className="matchup">
        <span className="team">{parts.team}</span>
        {parts.score}
      </div>
      <div className="under">
        {parts.under ? <span>{parts.under}</span> : null}
        <span className="mono">{parts.meta}</span>
      </div>
      {parts.err ? <div className="err">{parts.err}</div> : null}
    </>
  )

  const className = parts.variant ? `sl-game ${parts.variant}` : 'sl-game'

  // A card with nowhere to go stays a plain block rather than a dead link: there
  // is no run row and no build to open.
  if (!parts.to) return <div className={className}>{body}</div>

  return (
    <Link className={className} to={{ pathname: parts.to, search }}>
      {body}
    </Link>
  )
}
