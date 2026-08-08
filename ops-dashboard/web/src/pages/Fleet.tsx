import { useEffect, useState } from 'react'
import { fetchIncidentCounts, fetchOverview, fetchSports } from '../api/client.ts'
import type { AnomalyKind, OverviewPayload, SportPanel, SportSummary } from '../api/types.ts'
import { AnnotationNote } from '../components/AnnotationNote.tsx'
import type { FilterChip } from '../components/FilterChipRow.tsx'
import { FilterChipRow } from '../components/FilterChipRow.tsx'
import { Expander } from '../components/Expander.tsx'
import { HealthCard } from '../components/HealthCard.tsx'
import { HealthyAggregate } from '../components/HealthyAggregate.tsx'
import { Legend } from '../components/Legend.tsx'
import { EmptyState, QuietNote } from '../components/QuietNote.tsx'
import { SectionHead } from '../components/SectionHead.tsx'
import { StatTile } from '../components/StatTile.tsx'
import { TimelineBoard } from '../components/TimelineBoard.tsx'
import { TopBar } from '../components/TopBar.tsx'
import { ALL_SPORTS, useSportFilter } from '../hooks/useSportFilter.ts'
import { hhmm, longDay, num, weekday } from '../utils/format.ts'

const INCIDENT_DAYS = 7

const WORST_LABEL: Record<AnomalyKind, string> = {
  missing: 'WORST: RECORD MISSING',
  missed: 'WORST: MISSED SLOT',
  failure: 'WORST: FAILING',
  disagree: 'WORST: DISAGREEMENT',
  ok: 'ALL SUCCEEDED',
}

// A disagreement earns a panel badge but not the red one: it is unresolved,
// not failed.
const WORST_BAD = new Set<AnomalyKind>(['missing', 'missed', 'failure'])

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

interface PanelProps {
  panel: SportPanel
  open: boolean
  onToggle: () => void
}

function SportPanelSection({ panel, open, onToggle }: PanelProps) {
  const bad = WORST_BAD.has(panel.worst)

  return (
    <section className={panel.anomaly_count > 0 ? 'spanel attn' : 'spanel'}>
      {/* Clicking the row is a mouse convenience; the caret button is the
          accessible control, so it is the only nested interactive element. */}
      <div className="spanel-head" onClick={onToggle}>
        <span className="sname">{panel.sport}</span>
        <span className="cells">
          <span>
            <b>{panel.pipelines}</b> pipelines
          </span>
          <span className={bad ? 'worst bad' : 'worst'}>{WORST_LABEL[panel.worst]}</span>
          <span>
            <b className={panel.missed_slots_today > 0 ? 'bad' : undefined}>
              {panel.missed_slots_today}
            </b>{' '}
            missed slot{panel.missed_slots_today === 1 ? '' : 's'}
          </span>
          <span>
            <b>{num(panel.rows_today)}</b> rows today
          </span>
        </span>
        <span className="toggle">
          <Expander
            open={open}
            onToggle={onToggle}
            label={`${open ? 'Collapse' : 'Expand'} the ${panel.sport} panel`}
          />
        </span>
      </div>

      {open ? (
        <div className="spanel-body">
          {panel.anomaly_count > 0 ? (
            <div className="grid">
              {panel.cards.map((card) => (
                <HealthCard key={card.pipeline} sport={panel.sport} card={card} />
              ))}
              {panel.healthy_count > 0 ? <HealthyAggregate count={panel.healthy_count} /> : null}
            </div>
          ) : (
            <QuietNote>
              Nothing to render: all <b>{panel.pipelines}</b> pipelines are healthy today, 0
              anomalies. A healthy sport contributes exactly one header line to this page.
            </QuietNote>
          )}
        </div>
      ) : null}
    </section>
  )
}

export default function Fleet() {
  const { sport, setSport } = useSportFilter()
  const [allSports, setAllSports] = useState<SportSummary[]>([])
  const [overview, setOverview] = useState<OverviewPayload | null>(null)
  const [incidentCount, setIncidentCount] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [laneOverrides, setLaneOverrides] = useState<Record<string, boolean>>({})
  const [panelOverrides, setPanelOverrides] = useState<Record<string, boolean>>({})

  useEffect(() => {
    const control = new AbortController()
    fetchSports(control.signal)
      .then((payload) => setAllSports(payload.sports))
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [])

  useEffect(() => {
    const control = new AbortController()
    setError(null)
    setOverview(null)
    fetchOverview(sport, control.signal)
      .then(setOverview)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [sport])

  useEffect(() => {
    const control = new AbortController()
    setIncidentCount(null)
    fetchIncidentCounts(sport, INCIDENT_DAYS, control.signal)
      .then((payload) =>
        setIncidentCount(Object.values(payload.counts).reduce((total, n) => total + n, 0)),
      )
      // The strip must still render when only the incident count is unavailable.
      .catch(() => undefined)
    return () => control.abort()
  }, [sport])

  if (error) {
    return (
      <>
        <TopBar />
        <main className="wrap">
          <EmptyState message="Could not load the fleet overview" detail={error} bad />
        </main>
      </>
    )
  }

  if (!overview) {
    return (
      <>
        <TopBar />
        <main className="wrap">
          <EmptyState message="Loading fleet overview" />
        </main>
      </>
    )
  }

  const { summary, board } = overview
  const anomalies = new Map(overview.sports.map((panel) => [panel.sport, panel.anomaly_count]))
  const fleetPipelines = allSports.reduce((total, entry) => total + entry.pipelines, 0)

  const chips: FilterChip[] = [
    {
      value: ALL_SPORTS,
      label: 'All',
      count: fleetPipelines || summary.pipelines,
      anomalies:
        sport === ALL_SPORTS
          ? overview.sports.reduce((total, panel) => total + panel.anomaly_count, 0)
          : undefined,
    },
    ...allSports.map((entry) => ({
      value: entry.sport,
      label: entry.sport,
      count: entry.pipelines,
      // Undefined rather than 0 when the current payload does not cover it.
      anomalies: anomalies.get(entry.sport),
    })),
  ]

  const meta = `${weekday(overview.now)} ${overview.date} · ${summary.sports} sports · ${
    summary.pipelines
  } pipelines · DLT_DB.OPS · refreshed ${hhmm(overview.now)} UTC`

  return (
    <>
      <TopBar meta={meta} />
      <main className="wrap">
        <h1>Fleet overview</h1>
        <p className="subtitle">
          Sport is the unit of layout, mirroring the backend: one database and one V_PIPELINE_RUNS
          view per sport, so one panel and one board lane per sport. Detail appears only where
          something is wrong.
        </p>

        <div className="summary">
          <StatTile value={summary.pipelines} label={`Pipelines · ${summary.sports} sports`} />
          <StatTile value={summary.slots_today} label="Cron slots today" />
          <StatTile value={summary.succeeded_today} label="Succeeded" />
          <StatTile value={summary.failed_today} label="Failed" alert={summary.failed_today > 0} />
          <StatTile
            value={summary.missing_today}
            label="Record missing"
            alert={summary.missing_today > 0}
          />
          <StatTile
            value={summary.missed_today}
            label="Expected, no run"
            alert={summary.missed_today > 0}
          />
          <StatTile value={summary.upcoming_today} label="Upcoming" />
          <StatTile
            value={incidentCount ?? '.'}
            label={`Incidents · ${INCIDENT_DAYS} days`}
            to={{ pathname: '/incidents', search: sport === ALL_SPORTS ? '' : `?sport=${sport}` }}
          />
        </div>

        <FilterChipRow chips={chips} value={sport} onChange={setSport} />

        <AnnotationNote label="Annotation, global filter:">
          This one chip row scopes every page, including the incident feed, because "sport" is just
          a predicate pushed into each sport's V_PIPELINE_RUNS view. It lives in the URL as
          ?sport=, so a filtered view is shareable and survives a reload.
        </AnnotationNote>

        <SectionHead
          title="Today's schedule board"
          count={`${hhmm(board.window.start)} to ${hhmm(board.window.end)} UTC · ${longDay(
            overview.date,
          )} · one lane per sport, expand for pipelines`}
        />

        <Legend />

        <TimelineBoard
          window={board.window}
          now={overview.now}
          sports={board.sports}
          isExpanded={(name) => laneOverrides[name] ?? (anomalies.get(name) ?? 0) > 0}
          onToggle={(name) =>
            setLaneOverrides((current) => ({
              ...current,
              [name]: !(current[name] ?? (anomalies.get(name) ?? 0) > 0),
            }))
          }
        />

        <AnnotationNote label="Annotation, exaggerated widths:">
          A block's left edge is its real start time against the axis, but its width is duration at
          roughly 20x scale: real runs are 50 to 130 seconds and would be under two pixels on a true
          day-wide axis. Two stagger rows dodge overlaps in the rolled-up sport lanes. The hatched
          DLT_RECORD_MISSING block and the dashed "expected but no run row" slot render at the sport
          level too, so absence stays loud even when every lane is collapsed.
        </AnnotationNote>

        <SectionHead
          title="Sport panels"
          count="one rollup line per sport · cards render only for pipelines needing a human"
        />

        {overview.sports.map((panel) => (
          <SportPanelSection
            key={panel.sport}
            panel={panel}
            open={panelOverrides[panel.sport] ?? panel.anomaly_count > 0}
            onToggle={() =>
              setPanelOverrides((current) => ({
                ...current,
                [panel.sport]: !(current[panel.sport] ?? panel.anomaly_count > 0),
              }))
            }
          />
        ))}

        <AnnotationNote label="Annotation, management by exception:">
          Healthy pipelines never render a card, so the card count is the triage queue length rather
          than the fleet size. When every sport is healthy this page is a few one-line headers tall,
          whatever the sport count. Adding a sport adds lines, not screens.
        </AnnotationNote>
      </main>
    </>
  )
}
