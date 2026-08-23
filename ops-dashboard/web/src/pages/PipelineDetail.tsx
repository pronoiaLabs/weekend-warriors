import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { fetchPipelineDetail, fetchRunMetrics } from '../api/client.ts'
import type { AnomalyKind, MetricsPayload, PipelineDetailPayload, RunRow } from '../api/types.ts'
import { AnnotationNote } from '../components/AnnotationNote.tsx'
import { AnomalyBadge } from '../components/AnomalyBadge.tsx'
import Crumbs from '../components/Crumbs.tsx'
import { HeatLegend, HeatStrip } from '../components/HeatStrip.tsx'
import { LogTable } from '../components/LogTable.tsx'
import { MetricDotStrip } from '../components/MetricDotStrip.tsx'
import { EmptyState } from '../components/QuietNote.tsx'
import { SegmentedDurationBar } from '../components/SegmentedDurationBar.tsx'
import { StatusPill } from '../components/StatusPill.tsx'
import type { TabSpec } from '../components/Tabs.tsx'
import { Tabs } from '../components/Tabs.tsx'
import TileFrame from '../components/TileFrame.tsx'
import { VerdictPair } from '../components/VerdictPair.tsx'
import { useApi } from '../hooks/useApi.ts'
import { useBack } from '../hooks/useBack.ts'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import { bytes, cores, cronProse, dayHhmm, hhmm, num, relativeTo, shortDate } from '../utils/format.ts'
import { leagueLabel } from '../utils/leagues.ts'
import '../styles/pages/pipeline-detail.css'

// The list scrolls in its own window and only the selected run mounts its
// evidence, so depth costs neither page length nor fetches. The API caps at 50.
const RUN_LIMIT = 30
// The whole run's story: the log window scrolls in place, so page length no
// longer prices the limit. The API caps at 2000; container runs log a few
// hundred lines.
const LOG_LIMIT = 1000
// The placeholder for a number the window never produced. A middle dot, so it
// cannot be read as a zero.
const NONE = '·'

const PILL_STATE: Record<string, AnomalyKind> = {
  succeeded: 'ok',
  failure: 'failure',
  missing: 'missing',
  missed: 'missed',
}

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** The instant every relative time on this page is measured against. The
    payload carries no `now`, so the newest thing it describes stands in for
    one: the browser clock would age a stale tab all by itself. This is also
    why the page never calls setNow, since it has no clock of the API's to
    publish to the shell. */
function reference(detail: PipelineDetailPayload): string {
  const candidates = [detail.runs[0]?.run_started_at, detail.heatmap.at(-1)?.date]
    .filter((value): value is string => value != null)
    .map((value) => (value.length === 10 ? `${value}T00:00:00.000Z` : value))
  return candidates.reduce((latest, at) => (Date.parse(at) > Date.parse(latest) ? at : latest))
}

function Stat({ v, l, mono }: { v: string; l: string; mono?: boolean }) {
  return (
    <div className="stat">
      <span className={mono ? 'v mono' : 'v'}>{v}</span>
      <span className="l">{l}</span>
    </div>
  )
}

function ErrorPanel({ run }: { run: RunRow }) {
  const variant = run.dlt_record_missing ? 'missing' : run.state === 'failure' ? 'alarmed' : 'neutral'
  return (
    <>
      {run.error_text ? (
        <>
          <div className="errbox">{run.error_text}</div>
          <p className="pane-src">
            ERROR_TEXT resolved from {run.error_provenance ?? 'an unrecorded source'}. The view
            COALESCEs the dlt exception with TASK_HISTORY.ERROR_MESSAGE, so it never appears without
            saying which one it came from.
          </p>
        </>
      ) : (
        <p className="pane-src">
          ERROR_TEXT is NULL on this row · EXIT_STATUS {run.exit_status ?? 'NULL'}.
        </p>
      )}
      <div className="pane-label">Both verdicts, side by side</div>
      <VerdictPair taskState={run.task_state} dltStatus={run.dlt_status} variant={variant} />
    </>
  )
}

function MetricsPanel({ run }: { run: RunRow }) {
  const [payload, setPayload] = useState<MetricsPayload | null>(null)
  const [error, setError] = useState<string | null>(null)
  const absent = run.telemetry_available === false

  useEffect(() => {
    if (absent) return undefined
    const control = new AbortController()
    fetchRunMetrics(run.query_id, control.signal)
      .then(setPayload)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [run.query_id, absent])

  if (absent) {
    // Absence of telemetry is a finding in its own right, and an empty chart
    // would read as "nothing happened" instead.
    return (
      <>
        <p className="pane-src">
          METRIC_SAMPLES {num(run.metric_samples)} · TELEMETRY_AVAILABLE false: telemetry predates
          this run or the container died before the first scrape.
        </p>
        {run.container_never_started ? (
          <p className="pane-src bad">
            CONTAINER_NEVER_STARTED true: the container never ran at all, which is a different fact
            from a run that died between scrapes.
          </p>
        ) : null}
      </>
    )
  }

  if (error) return <p className="pane-src bad">Could not load V_METRICS: {error}</p>
  if (!payload) return <p className="pane-src">Loading V_METRICS...</p>

  return (
    <>
      <div className="metric-cards">
        <div className="mcard">
          <div className="mv">{cores(run.cpu_cores_max)}</div>
          <div className="mk">
            CPU_CORES_MAX of CPU_CORES_LIMIT {run.cpu_cores_limit ?? 'NULL'}
          </div>
          <MetricDotStrip
            name="container.cpu.usage"
            unit="core"
            points={payload.strips.cpu.points}
            limit={payload.strips.cpu.limit}
            limitLabel="CPU_CORES_LIMIT"
            maxLabel="CPU_CORES_MAX"
            max={run.cpu_cores_max}
            samplesLabel="CPU_SAMPLES"
            samples={run.cpu_samples}
            startAt={run.run_started_at}
            endAt={run.run_ended_at}
          />
        </div>
        <div className="mcard">
          <div className="mv">{bytes(run.mem_bytes_max)}</div>
          <div className="mk">
            MEM_BYTES_MAX of MEM_BYTES_REQUESTED {bytes(run.mem_bytes_requested)}
          </div>
          <MetricDotStrip
            name="container.memory.usage"
            unit="byte"
            points={payload.strips.memory.points}
            limit={payload.strips.memory.limit}
            limitLabel="MEM_BYTES_REQUESTED"
            maxLabel="MEM_BYTES_MAX"
            max={run.mem_bytes_max}
            samplesLabel="MEM_SAMPLES"
            samples={run.mem_samples}
            startAt={run.run_started_at}
            endAt={run.run_ended_at}
          />
        </div>
      </div>
      <p className="pane-src">
        METRIC_SAMPLES {num(payload.metric_samples)} rows across every metric · CPU_SAMPLES{' '}
        {num(payload.cpu_samples)} and MEM_SAMPLES {num(payload.mem_samples)} scrapes · RESTARTS{' '}
        {run.restarts ?? 'NULL'}
      </p>
    </>
  )
}

function RunListItem({
  run,
  selected,
  onSelect,
}: {
  run: RunRow
  selected: boolean
  onSelect: () => void
}) {
  const failed = run.state === 'failure' || run.state === 'missing'
  const classes = ['runitem', selected ? 'on' : '', failed ? 'bad' : ''].filter(Boolean).join(' ')
  return (
    <button
      type="button"
      className={classes}
      aria-pressed={selected}
      aria-label={`Show evidence for the run at ${dayHhmm(run.run_started_at)}`}
      onClick={onSelect}
    >
      <span className={failed ? 'outcome fail' : 'outcome'}>{run.task_state ?? 'NO STATE'}</span>
      <span className="ts">
        {shortDate(run.run_started_at)} · {hhmm(run.run_started_at)}
      </span>
      {run.dlt_record_missing ? <span className="flagdot missing" title="RECORD MISSING" /> : null}
      {run.outcome_disagrees ? <span className="flagdot disagrees" title="DISAGREES" /> : null}
      <span className="dur">{run.duration_s == null ? 'NULL' : `${run.duration_s}s`}</span>
    </button>
  )
}

function RunEvidence({ run, search }: { run: RunRow; search: string }) {
  const failed = run.state === 'failure' || run.state === 'missing'
  const scrapes = (run.cpu_samples ?? 0) + (run.mem_samples ?? 0)

  const tabs: TabSpec[] = [
    { id: 'error', label: 'Error', render: () => <ErrorPanel run={run} /> },
    {
      id: 'logs',
      label: `Logs · ${num(run.log_lines)}`,
      render: () => <LogTable queryId={run.query_id} limit={LOG_LIMIT} />,
    },
    {
      id: 'metrics',
      label: `Metrics · ${scrapes} scrapes`,
      render: () => <MetricsPanel run={run} />,
    },
  ]

  return (
    <section className={failed ? 'runpane bad' : 'runpane'}>
      <div className="runpane-head">
        <span className={failed ? 'outcome fail' : 'outcome'}>{run.task_state ?? 'NO STATE'}</span>
        <span className="ts">
          {shortDate(run.run_started_at)} · {hhmm(run.run_started_at)}
        </span>
        {run.dlt_record_missing ? <span className="flag missing">RECORD MISSING</span> : null}
        {/* The wireframe drew no chip for a disagreement; that omission was
            catalogued as a bug, because a disagreement is the one anomaly the
            outcome column cannot show. */}
        {run.outcome_disagrees ? <span className="flag disagrees">DISAGREES</span> : null}
        <span className="cells">
          <span>
            DURATION_S <b>{run.duration_s ?? 'NULL'}</b>
          </span>
          <span>
            ROWS_LOADED <b>{run.rows_loaded == null ? 'NULL' : num(run.rows_loaded)}</b>
          </span>
          <span>
            LOG_LINES <b>{run.log_lines == null ? 'NULL' : num(run.log_lines)}</b>
          </span>
        </span>
      </div>

      <div className="runpane-body">
        <SegmentedDurationBar
          durationS={run.duration_s}
          startupOverheadS={run.startup_overhead_s}
          containerSpanS={run.container_span_s}
          failed={failed}
        />
        <Tabs tabs={tabs} defaultTab={failed ? 'error' : 'logs'} scope={run.query_id} />
        <div className="runpane-foot">
          <Link to={{ pathname: `/runs/${run.query_id}`, search }}>Open full run detail</Link>
          <span>QUERY_ID {run.query_id}</span>
        </div>
      </div>
    </section>
  )
}

/** One ingestion pipeline read as a season: the schedule and the window's
    record up top, a cell per day of the window, then the run-by-run history
    with the selected run's evidence beside it. */
export default function PipelineDetail() {
  const { sport = '', name = '' } = useParams()
  const search = useOpsSearch()
  const back = useBack({ pathname: '/pipelines', search })
  const res = useApi((signal) => fetchPipelineDetail(sport, name, RUN_LIMIT, signal), [sport, name])
  // The selection is a query id, so it simply misses when the payload changes
  // pipeline and the newest run takes over again; nothing needs resetting.
  const [selectedRun, setSelectedRun] = useState<string | null>(null)

  const detail = res.data
  if (!detail) {
    return (
      <div className="page page-pipeline">
        <div className="crumb-row">
          <Crumbs
            items={[
              { label: 'Pipelines', to: { pathname: '/pipelines', search } },
              { label: res.error ? 'No such pipeline' : name },
            ]}
          />
          <button type="button" className="back" onClick={back}>
            <span aria-hidden="true">←</span> Back to pipelines
          </button>
        </div>
        <div className="page-head">
          <h1>{res.error ? `Could not load ${sport}/${name}` : `Loading ${name}`}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a pipeline from the{' '}
              <Link to={{ pathname: '/pipelines', search }}>records table</Link>.
            </p>
          )}
        </div>
      </div>
    )
  }

  const now = reference(detail)
  const latest = detail.runs[0] ?? null
  const state = latest ? (PILL_STATE[latest.state] ?? 'ok') : 'ok'
  // The newest run is selected until the user picks another; only the selected
  // run's evidence is mounted, so the list can hold many runs at no fetch cost.
  const currentRun = detail.runs.find((run) => run.query_id === selectedRun) ?? latest

  // Day counts for the red states, because the heatmap is exactly one cell per
  // day of the window; a disagreement never becomes a day's worst state, so it
  // is counted over the run rows instead.
  const dayCount = (kind: string) => detail.heatmap.filter((cell) => cell.state === kind).length
  const disagreements = detail.runs.filter((run) => run.outcome_disagrees)
  const failures = detail.runs_in_window - detail.succeeded

  return (
    <div className="page page-pipeline">
      <div className="crumb-row">
        <Crumbs
          items={[
            { label: 'Pipelines', to: { pathname: '/pipelines', search } },
            { label: detail.pipeline },
          ]}
        />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to pipelines
        </button>
      </div>

      <section className={state === 'ok' ? 'tile pipe-head' : 'tile pipe-head attn'} data-tilt="">
        <div className="ident">
          <span className="kick">
            {/* The sport goes to the records table scoped to that league, never
                to the dashboard with a silently stamped filter: that exact
                surprise is why this link was rewritten. */}
            <Link to={{ pathname: '/pipelines', search: `?sport=${detail.sport}` }}>
              {leagueLabel(detail.sport)}
            </Link>{' '}
            · ingestion
          </span>
          <h1>{detail.pipeline}</h1>
          <div className="badges">
            <StatusPill state={state} />
            {dayCount('missing') > 0 ? (
              <AnomalyBadge
                kind="missing"
                count={dayCount('missing')}
                windowDays={detail.window_days}
              />
            ) : null}
            {dayCount('failure') > 0 ? (
              <AnomalyBadge
                kind="failure"
                count={dayCount('failure')}
                windowDays={detail.window_days}
              />
            ) : null}
            {dayCount('missed') > 0 ? (
              <AnomalyBadge kind="missed" count={dayCount('missed')} />
            ) : null}
            {disagreements.length > 0 ? (
              <AnomalyBadge
                kind="disagree"
                count={disagreements.length}
                lastAt={disagreements[0].run_started_at}
              />
            ) : null}
          </div>
          <p className="lede">
            Runs {cronProse(detail.cron)}, next {dayHhmm(detail.next_fire)}. One Snowflake Task per
            pipeline, one container per fire, and every fact below comes from that Task's own run
            rows over the last {detail.window_days} days.
          </p>
        </div>
        <div className="line-strip">
          <Stat v={detail.cron} l={`Schedule · ${cronProse(detail.cron)}`} mono />
          <Stat v={dayHhmm(detail.next_fire)} l="Next fire" />
          <Stat v={detail.task_name ?? 'not on any run row'} l="TASK_NAME" mono />
          <Stat v={detail.compute_pool ?? 'not on any run row'} l="COMPUTE_POOL" mono />
        </div>
      </section>

      <div className="kpis four">
        <div className={failures > 0 ? 'kpi bad' : 'kpi good'}>
          <span className="l">Succeeded</span>
          <span className="v">
            {detail.succeeded}/{detail.runs_in_window}
          </span>
          <span className="s">
            {failures > 0 ? `${failures} did not succeed` : 'every run in the window'}
          </span>
        </div>
        <div className="kpi">
          <span className="l">Median duration</span>
          <span className="v">
            {detail.median_duration_s == null ? NONE : `${detail.median_duration_s}s`}
          </span>
          <span className="s">
            {detail.median_duration_s == null ? 'no successful run' : 'DURATION_S, middle run'}
          </span>
        </div>
        <div className="kpi">
          <span className="l">Last success</span>
          <span className="v">
            {detail.last_success_at ? relativeTo(detail.last_success_at, now) : 'none'}
          </span>
          <span className="s">
            {detail.last_success_at
              ? dayHhmm(detail.last_success_at)
              : `nothing succeeded in ${detail.window_days} days`}
          </span>
        </div>
        <div className="kpi">
          <span className="l">Window</span>
          <span className="v">{detail.window_days}</span>
          <span className="s">days, one heat cell each</span>
        </div>
      </div>

      <TileFrame
        title={`Last ${detail.window_days} days`}
        meta="one cell per day"
        className="heat-tile"
      >
        <HeatStrip cells={detail.heatmap} />
        <HeatLegend />
        <AnnotationNote label="Annotation, read across:">
          The strip sits above the run history so a streak is visible without leaving the page. Read
          across rather than down: cells of the same class landing on the same weekday point at an
          upstream refresh cadence rather than at the container, and {detail.window_days} days are
          shown because a weekly pattern needs at least two data points. A cell with no run row is
          drawn dashed and links nowhere, since there is nothing to open. Each cell carries the worst
          state of its day and opens that day's run.
        </AnnotationNote>
      </TileFrame>

      <TileFrame
        title="Run history"
        meta={`last ${detail.runs.length} of ${detail.runs_in_window} in the window`}
        className="runs-tile"
        caption="Select a run for its evidence: the error and both verdicts, the container's logs, the metric scrapes."
      >
        {currentRun == null ? (
          <EmptyState message={`No run row in the last ${detail.window_days} days.`} />
        ) : (
          <div className="runsplit">
            <div className="runlist" role="group" aria-label="Runs in the window">
              {detail.runs.map((run) => (
                <RunListItem
                  key={run.query_id}
                  run={run}
                  selected={run.query_id === currentRun.query_id}
                  onSelect={() => setSelectedRun(run.query_id)}
                />
              ))}
            </div>
            <RunEvidence run={currentRun} search={search} />
          </div>
        )}
      </TileFrame>

      <TileFrame title="How this page is built" className="note-tile" query={detail.query}>
        <p>
          One select on the pipeline's run rows in DLT_DB.OPS: the heatmap is the worst state of each
          day of the window, the record is TASK_HISTORY joined to what the pipeline itself recorded
          in _DLT_RUNS, and the two verdicts are always shown side by side rather than merged.
        </p>
        <p>
          The duration bar splits STARTUP_OVERHEAD_S from CONTAINER_SPAN_S because the two fail
          differently: a run that dies inside the hatched zone is an infrastructure or spec problem,
          one that dies in the solid zone is a data or API problem. The heatmap up top and that bar
          down there answer the same question at two zoom levels, when this pipeline breaks and how
          far into a run.
        </p>
      </TileFrame>
    </div>
  )
}
