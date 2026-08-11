import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { fetchIncidents } from '../api/client.ts'
import type {
  Incident,
  IncidentKind,
  IncidentsPayload,
  MissedIncident,
  RunIncident,
} from '../api/types.ts'
import { AnnotationNote } from '../components/AnnotationNote.tsx'
import type { FilterChip } from '../components/FilterChipRow.tsx'
import { FilterChipRow } from '../components/FilterChipRow.tsx'
import { MiniRunStrip } from '../components/MiniRunStrip.tsx'
import { EmptyState } from '../components/QuietNote.tsx'
import { SeverityBadge } from '../components/SeverityBadge.tsx'
import { TopBar } from '../components/TopBar.tsx'
import { VerdictPair } from '../components/VerdictPair.tsx'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { dayHhmm, hhmm, longDayTitle, num } from '../utils/format.ts'

const INCIDENT_DAYS = 7
const ALL_KINDS = 'all'

const TITLES: Record<IncidentKind, string> = {
  missing: 'Task failed and the run never recorded itself',
  missed: 'Cron slot passed with no run row at all',
  failure: 'Task failed and the pipeline recorded the failure',
  disagree: 'Snowflake and the pipeline disagree about this run',
}

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** Relative age against the payload's own `now`. The browser clock is never
    consulted: a stale tab would otherwise quietly age every incident. */
function relative(at: string, now: string): string {
  const minutes = Math.max(0, Math.round((Date.parse(now) - Date.parse(at)) / 60000))
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h ago`
  const days = Math.floor(hours / 24)
  return days === 1 ? 'yesterday' : `${days} days ago`
}

function shortQueryId(id: string): string {
  return id.length > 16 ? `${id.slice(0, 8)}...${id.slice(-4)}` : id
}

interface DayGroup {
  day: string
  entries: Incident[]
}

/** The feed arrives newest first, so contiguous runs of one date are the
    groups; a day emptied by the kind filter never produces a header. */
function groupByDay(entries: Incident[]): DayGroup[] {
  const groups: DayGroup[] = []
  for (const entry of entries) {
    const day = entry.at.slice(0, 10)
    const last = groups.at(-1)
    if (last && last.day === day) {
      last.entries.push(entry)
    } else {
      groups.push({ day, entries: [entry] })
    }
  }
  return groups
}

/** ERROR_TEXT is a COALESCE of two sources, so it never appears without saying
    which one it came from. The provenance string is quoted verbatim rather than
    folded into the uppercase label. */
function ErrorExcerpt({ entry }: { entry: RunIncident }) {
  return (
    <>
      <code>{entry.error_text ?? 'no ERROR_TEXT on this row'}</code>
      {entry.error_provenance ? (
        <div className="src-note">resolved from {entry.error_provenance}</div>
      ) : null}
    </>
  )
}

function FailureEvidence({ entry }: { entry: RunIncident }) {
  const counts: string[] = []
  if (entry.log_lines != null) counts.push(`LOG_LINES ${num(entry.log_lines)}`)
  if (entry.error_lines != null) counts.push(`ERROR_LINES ${num(entry.error_lines)}`)

  return (
    <div className="evidence">
      <div className="label">ERROR_TEXT excerpt</div>
      <ErrorExcerpt entry={entry} />
      {entry.dlt_status ? (
        <>
          <div className="label gap">Both verdicts recorded</div>
          TASK_STATE = {entry.task_state ?? 'NULL'} and DLT_STATUS = {entry.dlt_status}. The run got
          far enough to record itself, so logs and metrics exist for it
          {counts.length ? ` (${counts.join(' · ')})` : null}.
        </>
      ) : null}
      {entry.next_outcome ? (
        <>
          <div className="label gap">Next outcome</div>
          next run {entry.next_outcome.task_state ?? 'no TASK_STATE'} at{' '}
          {dayHhmm(entry.next_outcome.at)} UTC
        </>
      ) : null}
    </div>
  )
}

function MissingEvidence({ entry }: { entry: RunIncident }) {
  return (
    <div className="evidence">
      <div className="label">What this means</div>
      The run died before the pipeline could record itself: Snowflake saw the failure, but there is
      no matching row on the dlt side, so DLT_STATUS is NULL and there is no LOAD_ID. Historically 22
      Task failures produced only 17 self-recorded rows, which is why this feed is built on
      TASK_HISTORY rather than the pipeline's own log.
      <div className="label gap">The two sources, side by side</div>
      <VerdictPair taskState={entry.task_state} dltStatus={entry.dlt_status} variant="missing" />
      <div className="label gap">ERROR_TEXT excerpt</div>
      <ErrorExcerpt entry={entry} />
    </div>
  )
}

function DisagreeEvidence({ entry }: { entry: RunIncident }) {
  return (
    <div className="evidence">
      <VerdictPair taskState={entry.task_state} dltStatus={entry.dlt_status} variant="neutral" />
      <div className="label gap">Why it can happen</div>
      The container exited cleanly, so the Task graph reports one outcome, while the pipeline
      recorded another for the same run. Neither side has been ruled out, so the disagreement itself
      is the finding: OUTCOME_DISAGREES = true, and merging the two into a single status is exactly
      what would hide it.
      {entry.load_id ? (
        <>
          {' '}
          {entry.rows_loaded == null ? 'Rows' : `${num(entry.rows_loaded)} rows`} carry LOAD_ID{' '}
          {entry.load_id} and may be a partial load.
        </>
      ) : null}
    </div>
  )
}

function MissedEvidence({ entry }: { entry: MissedIncident }) {
  return (
    <div className="evidence">
      <div className="label">What this means</div>
      The registry says {entry.pipeline} fires {entry.schedule}. The slot passed and V_PIPELINE_RUNS
      has no row: no TASK_STATE, no failure, nothing. That silence is the signature of a suspended
      Task, and a whole fleet of suspended Tasks looks like a perfectly green dashboard with a wall
      of these. Filed as an incident precisely because no other view would raise it.
      <MiniRunStrip
        slots={entry.slot_strip}
        trailingMissed
        caption="this slot, recent days · dashed = expected but no run row"
      />
      <div className="label gap">First check</div>
      <code>
        SHOW TASKS IN SCHEMA DLT_DB.OPS · a state of "suspended" here explains everything, and
        CREATE OR ALTER TASK leaves a Task suspended after apply
      </code>
    </div>
  )
}

function RunFoot({ entry }: { entry: RunIncident }) {
  const meta: string[] = []
  if (entry.query_id) meta.push(`QUERY_ID ${shortQueryId(entry.query_id)}`)
  if (entry.duration_s != null) meta.push(`DURATION_S ${entry.duration_s}`)
  if (entry.rows_loaded != null) meta.push(`ROWS_LOADED ${num(entry.rows_loaded)}`)

  return (
    <div className="inc-foot">
      {entry.query_id ? <Link to={`/runs/${entry.query_id}`}>open run</Link> : null}
      <span>{meta.length ? meta.join(' · ') : 'no run metadata on this row'}</span>
    </div>
  )
}

interface ArticleProps {
  entry: Incident
  now: string
  search: string
}

function IncidentArticle({ entry, now, search }: ArticleProps) {
  const when =
    entry.kind === 'missed'
      ? `${hhmm(entry.at)} UTC slot · noticed ${hhmm(entry.noticed)}`
      : `${hhmm(entry.at)} UTC · ${relative(entry.at, now)}`

  // The left strip carries the severity; the badge is only the label chip.
  return (
    <article className={`incident sev-${entry.kind}`}>
      <div className="inc-top">
        <SeverityBadge kind={entry.kind} />
        <Link
          className="pipe"
          to={{ pathname: `/ingestion/${entry.sport}/${entry.pipeline}`, search }}
        >
          {entry.pipeline}
        </Link>
        <span className="when">{when}</span>
      </div>

      <p className="inc-title">{TITLES[entry.kind]}</p>

      {entry.kind === 'missed' ? <MissedEvidence entry={entry} /> : null}
      {entry.kind === 'missing' ? <MissingEvidence entry={entry} /> : null}
      {entry.kind === 'failure' ? <FailureEvidence entry={entry} /> : null}
      {entry.kind === 'disagree' ? <DisagreeEvidence entry={entry} /> : null}

      {entry.kind === 'missed' ? (
        <div className="inc-foot">
          <span>no QUERY_ID · no run row exists to link</span>
        </div>
      ) : (
        <RunFoot entry={entry} />
      )}
    </article>
  )
}

export default function Incidents() {
  const { sport, search } = useSportFilter()
  const [payload, setPayload] = useState<IncidentsPayload | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Kind is page-local, not URL state: the sport predicate is what other pages
  // and shared links care about.
  const [kind, setKind] = useState<string>(ALL_KINDS)

  useEffect(() => {
    const control = new AbortController()
    setError(null)
    setPayload(null)
    fetchIncidents(sport, INCIDENT_DAYS, control.signal)
      .then(setPayload)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [sport])

  if (error) {
    return (
      <>
        <TopBar />
        <main className="wrap narrow">
          <EmptyState message="Could not load the incident feed" detail={error} bad />
        </main>
      </>
    )
  }

  if (!payload) {
    return (
      <>
        <TopBar />
        <main className="wrap narrow">
          <EmptyState message="Loading incident feed" />
        </main>
      </>
    )
  }

  const { counts } = payload
  const total = counts.failure + counts.missing + counts.disagree + counts.missed
  const visible =
    kind === ALL_KINDS
      ? payload.incidents
      : payload.incidents.filter((entry) => entry.kind === kind)
  const groups = groupByDay(visible)

  // Counts describe the whole window, never the current selection: a chip that
  // renumbered itself once pressed would hide the other three classes.
  const chips: FilterChip[] = [
    { value: ALL_KINDS, label: 'All', count: total },
    { value: 'failure', label: 'Failures', count: counts.failure },
    { value: 'disagree', label: 'Disagreements', count: counts.disagree },
    { value: 'missing', label: 'Missing records', count: counts.missing },
    { value: 'missed', label: 'Missed slots', count: counts.missed },
  ]

  return (
    <>
      <TopBar
        meta={`${total} incidents · last ${payload.days} days · refreshed ${hhmm(
          payload.now,
        )} UTC`}
      />
      <main className="wrap narrow">
        <h1>Incident feed</h1>
        <p className="subtitle">
          Every bad event, newest first. Spine is TASK_HISTORY via V_PIPELINE_RUNS, outer-joined to
          the cron schedule so an empty slot can appear here too.
        </p>

        <AnnotationNote label="Annotation, the fourth incident class:">
          A cron time that passes with no row in V_PIPELINE_RUNS files an incident just like a
          failure does, because a fully suspended fleet produces exactly this pattern while
          reporting zero failures. It renders with a dashed border, matching the dashed slot on the
          schedule board, so the same state looks the same everywhere.
        </AnnotationNote>

        <FilterChipRow caption="Type" chips={chips} value={kind} onChange={setKind} />

        {groups.length === 0 ? (
          <EmptyState message={`No incidents match this filter in the last ${payload.days} days.`} />
        ) : (
          groups.map((group) => (
            <div key={group.day}>
              <div className="day-head">{longDayTitle(group.day)}</div>
              {group.entries.map((entry) => (
                <IncidentArticle
                  key={`${entry.kind}-${entry.pipeline}-${entry.at}`}
                  entry={entry}
                  now={payload.now}
                  search={search}
                />
              ))}
            </div>
          ))
        )}

        <AnnotationNote label="Annotation, severity is a class, not a score:">
          RECORD MISSING outranks FAILURE because it removes the evidence a failure would normally
          leave; MISSED SLOT sits beside it because it removes even the failure. DISAGREEMENT stays
          neutral gray because the run may be fine, and painting it red would train people to ignore
          red.
        </AnnotationNote>
      </main>
    </>
  )
}
