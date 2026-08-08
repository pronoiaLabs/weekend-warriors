import { Link } from 'react-router-dom'
import type { PipelineCard } from '../api/types.ts'
import { hhmm, num, weekday } from '../utils/format.ts'
import { AnomalyBadge } from './AnomalyBadge.tsx'
import { StatusPill } from './StatusPill.tsx'

const HARD_STATES = new Set(['missing', 'missed', 'failure'])

// A DLT_RECORD_MISSING run is still a FAILED Task; the missing record is the
// extra fact, not a different verdict.
const RUN_WORDS: Record<string, string> = {
  succeeded: 'SUCCEEDED',
  failure: 'FAILED',
  missing: 'FAILED',
}

interface Props {
  sport: string
  card: PipelineCard
}

function Verdict({ label, value }: { label: string; value: string | null }) {
  const failed = value === 'FAILED' || value === 'failed'
  return (
    <span className="verdict">
      <span className="vk">{label}</span>
      <b className={value == null ? 'none' : failed ? 'fail' : undefined}>{value ?? 'no row'}</b>
    </span>
  )
}

function LastRun({ card }: { card: PipelineCard }) {
  const run = card.last_run
  if (!run) {
    return (
      <div className="lastrun">
        No run row in the window · <b className="fail">nothing to open</b>
      </div>
    )
  }
  const failed = run.state === 'failure' || run.state === 'missing'
  return (
    <div className="lastrun">
      Last run <b className={failed ? 'fail' : undefined}>{RUN_WORDS[run.state] ?? run.state}</b> ·{' '}
      {weekday(run.at)} {hhmm(run.at)}
      {run.state === 'missing' ? (
        <>
          {' · '}
          <b className="fail">DLT_RECORD_MISSING = true</b>
        </>
      ) : null}
      {run.duration_s == null ? null : ` · ${run.duration_s} s`}
      {run.rows_loaded == null ? null : ` · ${num(run.rows_loaded)} rows`}
      {run.error_excerpt ? <span className="excerpt">{run.error_excerpt}</span> : null}
    </div>
  )
}

export function HealthCard({ sport, card }: Props) {
  return (
    <Link
      className={HARD_STATES.has(card.state) ? 'card attention' : 'card'}
      to={`/pipelines/${sport}/${card.pipeline}`}
    >
      <div className="card-top">
        <span className="name">{card.pipeline}</span>
        <StatusPill state={card.state} />
      </div>

      {/* The two verdicts stay separate: merging them is what hides a run that
          dlt called failed while the Task reported SUCCEEDED. */}
      <div className="verdicts">
        <Verdict label="TASK_STATE" value={card.task_state} />
        <Verdict label="DLT_STATUS" value={card.dlt_status} />
      </div>

      {card.missed_slots_today > 0 ? (
        <div className="lastrun">
          {card.missed_slots_today} slot{card.missed_slots_today > 1 ? 's' : ''} passed today ·{' '}
          <b className="fail">no run row</b>
        </div>
      ) : null}

      <LastRun card={card} />

      <div className="badges">
        {card.state === 'failure' ? <AnomalyBadge kind="failure" /> : null}
        {card.missed_slots_today > 0 ? (
          <AnomalyBadge kind="missed" count={card.missed_slots_today} />
        ) : null}
        {card.badges.map((badge) => (
          <AnomalyBadge
            key={badge.kind}
            kind={badge.kind}
            count={badge.count}
            windowDays={badge.window_days}
            lastAt={badge.last_at}
          />
        ))}
      </div>
    </Link>
  )
}
