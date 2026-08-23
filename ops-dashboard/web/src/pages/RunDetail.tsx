import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { fetchRun, fetchRunMetrics, fetchRunRowCounts } from '../api/client.ts'
import type {
  AnomalyKind,
  MetricsPayload,
  RowCountsPayload,
  RunDetailPayload,
  SlotSample,
} from '../api/types.ts'
import { AnnotationNote } from '../components/AnnotationNote.tsx'
import Crumbs from '../components/Crumbs.tsx'
import { LogTable } from '../components/LogTable.tsx'
import { MetricDotStrip } from '../components/MetricDotStrip.tsx'
import { MiniRunStrip } from '../components/MiniRunStrip.tsx'
import { SegmentedDurationBar } from '../components/SegmentedDurationBar.tsx'
import { StatusPill } from '../components/StatusPill.tsx'
import type { TabSpec } from '../components/Tabs.tsx'
import { Tabs } from '../components/Tabs.tsx'
import TileFrame from '../components/TileFrame.tsx'
import { VerdictPair } from '../components/VerdictPair.tsx'
import { useApi } from '../hooks/useApi.ts'
import { useBack } from '../hooks/useBack.ts'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import { bytes, compact, dayDate, duration, hhmmss, metricValue, num } from '../utils/format.ts'
import '../styles/pages/run-detail.css'

// The whole run's story: the log window scrolls in place, so page length no
// longer prices the limit. The API caps at 2000; container runs log a few
// hundred lines.
const LOG_LIMIT = 1000

// The pill speaks the anomaly vocabulary, the row speaks the block vocabulary;
// anything the API did not classify falls through to healthy rather than
// inventing a severity, the same mapping the pipeline page uses.
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

function bool(value: boolean | null): string {
  return value == null ? 'NULL' : String(value)
}

/** Enough of a Snowflake query id to recognise the run in a crumb; the whole
    thing stays on the page, in the head and in the run facts. */
function shortId(queryId: string): string {
  return queryId.length > 10 ? `${queryId.slice(0, 10)}...` : queryId
}

interface FactSpec {
  k: string
  v: string
  bad?: boolean
  note?: string
}

/** Every column of the row, labelled with its own uppercase column name so the
    page and a `SELECT *` read the same. A maximum never appears without the
    sample count it was taken from. */
function runFacts(run: RunDetailPayload): FactSpec[] {
  const failed = run.task_state === 'FAILED'
  return [
    { k: 'PIPELINE', v: run.pipeline },
    { k: 'SPORT', v: run.sport },
    { k: 'TASK_NAME', v: run.task_name ?? 'NULL' },
    { k: 'QUERY_ID', v: run.query_id },
    { k: 'SERVICE_NAME', v: run.service_name ?? 'NULL' },
    { k: 'COMPUTE_POOL', v: run.compute_pool ?? 'NULL' },
    { k: 'RUN_STARTED_AT', v: hhmmss(run.run_started_at) },
    { k: 'RUN_ENDED_AT', v: run.run_ended_at ? hhmmss(run.run_ended_at) : 'NULL' },
    { k: 'DURATION_S', v: String(run.duration_s ?? 'NULL') },
    { k: 'CONTAINER_SPAN_S', v: String(run.container_span_s ?? 'NULL') },
    { k: 'STARTUP_OVERHEAD_S', v: String(run.startup_overhead_s ?? 'NULL') },
    { k: 'TASK_STATE', v: run.task_state ?? 'NULL', bad: failed },
    { k: 'DLT_STATUS', v: run.dlt_status ?? 'NULL', bad: run.dlt_status === 'failed' },
    { k: 'OUTCOME_DISAGREES', v: bool(run.outcome_disagrees), bad: run.outcome_disagrees === true },
    {
      k: 'DLT_RECORD_MISSING',
      v: bool(run.dlt_record_missing),
      bad: run.dlt_record_missing === true,
    },
    {
      k: 'ROWS_LOADED',
      v: run.rows_loaded == null ? 'NULL' : num(run.rows_loaded),
      bad: !run.rows_loaded,
    },
    { k: 'LOAD_ID', v: run.load_id ?? 'NULL' },
    { k: 'RESOURCES', v: run.resources?.join(', ') || 'NULL' },
    {
      k: 'EXIT_STATUS',
      v: run.exit_status ?? 'NULL',
      note: run.exit_status ? '(container exited nonzero)' : '(no container exit code recorded)',
    },
    { k: 'RESTARTS', v: String(run.restarts ?? 'NULL') },
    {
      k: 'CONTAINER_NEVER_STARTED',
      v: bool(run.container_never_started),
      bad: run.container_never_started === true,
    },
    { k: 'TELEMETRY_AVAILABLE', v: bool(run.telemetry_available) },
    { k: 'LOG_LINES', v: run.log_lines == null ? 'NULL' : num(run.log_lines) },
    {
      k: 'ERROR_LINES',
      v: run.error_lines == null ? 'NULL' : num(run.error_lines),
      bad: (run.error_lines ?? 0) > 0,
    },
    { k: 'WARNING_LINES', v: run.warning_lines == null ? 'NULL' : num(run.warning_lines) },
    { k: 'UNPARSED_LINES', v: run.unparsed_lines == null ? 'NULL' : num(run.unparsed_lines) },
    {
      k: 'METRIC_SAMPLES',
      v: run.metric_samples == null ? 'NULL' : num(run.metric_samples),
      note: 'rows across every metric',
    },
    {
      k: 'CPU_CORES_MAX',
      v: run.cpu_cores_max == null ? 'NULL' : run.cpu_cores_max.toFixed(2),
      note: `from CPU_SAMPLES ${run.cpu_samples ?? 0}`,
    },
    { k: 'CPU_CORES_LIMIT', v: String(run.cpu_cores_limit ?? 'NULL') },
    {
      k: 'MEM_BYTES_MAX',
      v: bytes(run.mem_bytes_max),
      note: `from MEM_SAMPLES ${run.mem_samples ?? 0}`,
    },
    { k: 'MEM_BYTES_REQUESTED', v: bytes(run.mem_bytes_requested) },
  ]
}

/** The row as a definition list, two pairs to a line on a wide screen. */
function Facts({ facts }: { facts: FactSpec[] }) {
  return (
    <dl className="facts">
      {facts.map((fact) => (
        <div className="fact" key={fact.k}>
          <dt>{fact.k}</dt>
          <dd className={fact.bad ? 'bad' : undefined}>
            {fact.v}
            {fact.note ? <small> {fact.note}</small> : null}
          </dd>
        </div>
      ))}
    </dl>
  )
}

function MetricsTab({ run }: { run: RunDetailPayload }) {
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
    return (
      <>
        <p className="pane-src">
          METRIC_SAMPLES {num(run.metric_samples)} · TELEMETRY_AVAILABLE false: telemetry predates
          this run or the container died before the first scrape.
        </p>
        {run.container_never_started ? (
          <p className="pane-src bad">
            CONTAINER_NEVER_STARTED true: the container never ran at all. That is a real signal, and
            a different one from a run that started and died between scrapes.
          </p>
        ) : (
          <p className="pane-src">
            CONTAINER_NEVER_STARTED false: the container did start, so the missing samples are a
            scrape boundary rather than a container that never existed.
          </p>
        )}
      </>
    )
  }

  if (error) return <p className="pane-src bad">Could not load V_METRICS: {error}</p>
  if (!payload) return <p className="pane-src">Loading V_METRICS...</p>

  const names = Object.keys(payload.metrics).sort()

  return (
    <>
      <div className="pane-src">
        V_METRICS where QUERY_ID = {run.query_id} · NODE_INSTANCE_FAMILY{' '}
        {payload.node_instance_family ?? 'NULL'}
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
        samples={payload.cpu_samples}
        startAt={run.run_started_at}
        endAt={run.run_ended_at}
      />
      <MetricDotStrip
        name="container.memory.usage"
        unit="byte"
        points={payload.strips.memory.points}
        limit={payload.strips.memory.limit}
        limitLabel="MEM_BYTES_REQUESTED"
        maxLabel="MEM_BYTES_MAX"
        max={run.mem_bytes_max}
        samplesLabel="MEM_SAMPLES"
        samples={payload.mem_samples}
        startAt={run.run_started_at}
        endAt={run.run_ended_at}
      />

      <AnnotationNote label="Annotation, dots and not curves:" style={{ margin: '6px 0 16px' }}>
        The platform scrapes roughly every 30 seconds against runs of well under three minutes, so a
        run yields a handful of samples per metric. A maximum drawn from CPU_SAMPLES{' '}
        {num(payload.cpu_samples)} is a coarse floor on the true peak rather than the peak, which is
        why every maximum on this page carries its sample count and why nothing here is joined into
        a line. METRIC_SAMPLES {num(payload.metric_samples)} counts rows across every metric, not
        scrapes.
      </AnnotationNote>

      {/* `standings` is the shared records table, so the evidence panes borrow
          the page's one table treatment rather than carrying their own. */}
      <table className="standings">
        <thead>
          <tr>
            <th>METRIC_NAME</th>
            <th>METRIC_GROUP</th>
            <th className="num">samples</th>
            <th className="num">max</th>
            <th>METRIC_UNIT</th>
          </tr>
        </thead>
        <tbody>
          {names.map((name) => {
            const metric = payload.metrics[name]
            return (
              <tr key={name}>
                <td>{name}</td>
                <td>{metric.group ?? 'NULL'}</td>
                <td className="num">{num(metric.samples)}</td>
                <td className="num">{metricValue(metric.max, metric.unit)}</td>
                <td>{metric.unit ?? 'NULL'}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </>
  )
}

function RowCountsTab({ run }: { run: RunDetailPayload }) {
  const [payload, setPayload] = useState<RowCountsPayload | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const control = new AbortController()
    fetchRunRowCounts(run.query_id, control.signal)
      .then(setPayload)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [run.query_id])

  if (error) return <p className="pane-src bad">Could not load ROW_COUNTS: {error}</p>
  if (!payload) return <p className="pane-src">Loading ROW_COUNTS...</p>

  const current = payload.row_counts ?? {}
  const previous = payload.prev_row_counts ?? {}
  // A table that vanished this run still has to appear, so the rows are the
  // union of both keysets rather than this run's alone.
  const tables = [...new Set([...Object.keys(current), ...Object.keys(previous)])].sort()

  return (
    <>
      <div className="pane-src">ROW_COUNTS per-table JSON from _DLT_RUNS</div>
      {tables.length === 0 ? (
        <p className="pane-src">
          ROW_COUNTS is NULL on this row and on every earlier populated run in the window.
        </p>
      ) : (
        <table className="standings">
          <thead>
            <tr>
              <th>table</th>
              <th className="num">rows this run</th>
              <th className="num">rows previous run</th>
            </tr>
          </thead>
          <tbody>
            {tables.map((table) => (
              <tr key={table}>
                <td>{table}</td>
                <td className="num">{table in current ? num(current[table]) : 'absent'}</td>
                <td className="num">{table in previous ? num(previous[table]) : 'absent'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="pane-src after">
        ROWS_LOADED {payload.rows_loaded == null ? 'NULL' : num(payload.rows_loaded)} · the previous
        column is the most recent earlier run that populated ROW_COUNTS at all, carried here as
        context; it is not part of this run's row.
      </p>
    </>
  )
}

/** One run of one pipeline, end to end: the two verdicts side by side, where
    its seconds went, every column of its V_PIPELINE_RUNS row, and the logs,
    metrics and row counts filed under its QUERY_ID. */
export default function RunDetail() {
  const { queryId = '' } = useParams()
  const search = useOpsSearch()
  // No `now`: a run payload carries no clock, and the head says when this one
  // ran, so nothing here should date the shell.
  const res = useApi((signal) => fetchRun(queryId, signal), [queryId])
  const run = res.data
  const back = useBack({
    pathname: `/ingestion/${run?.sport ?? ''}/${run?.pipeline ?? ''}`,
    search,
  })

  if (!run) {
    return (
      <div className="page page-run">
        <Crumbs
          items={[
            { label: 'Pipelines', to: { pathname: '/pipelines', search } },
            { label: res.error ? 'No such run' : shortId(queryId) },
          ]}
        />
        <div className="page-head">
          <h1>{res.error ? 'Could not load this run' : 'Loading run...'}</h1>
          <p className="lede">{res.error ?? `QUERY_ID ${queryId}`}</p>
        </div>
      </div>
    )
  }

  const failed = run.task_state === 'FAILED'
  const variant = run.dlt_record_missing ? 'missing' : failed ? 'alarmed' : 'neutral'
  const scrapes = (run.cpu_samples ?? 0) + (run.mem_samples ?? 0)
  const pipelineHref = { pathname: `/ingestion/${run.sport}/${run.pipeline}`, search }

  // The strip runs oldest to newest with this run last and outlined, so the
  // same slot on previous days reads left to right like the board.
  const slots: SlotSample[] = [
    ...[...run.prior_runs].reverse().map((prior) => ({ at: prior.at, state: prior.state })),
    { at: run.run_started_at, state: run.state },
  ]

  const tabs: TabSpec[] = [
    {
      id: 'logs',
      label: `Logs · ${num(run.log_lines)}`,
      render: () => <LogTable queryId={run.query_id} limit={LOG_LIMIT} />,
    },
    {
      id: 'metrics',
      label: `Metrics · ${scrapes} scrapes`,
      render: () => <MetricsTab run={run} />,
    },
    { id: 'rows', label: 'Row counts', render: () => <RowCountsTab run={run} /> },
  ]

  return (
    <div className="page page-run">
      <div className="crumb-row">
        <Crumbs
          items={[
            { label: 'Pipelines', to: { pathname: '/pipelines', search } },
            { label: run.pipeline, to: pipelineHref },
            { label: `Run ${shortId(run.query_id)}` },
          ]}
        />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to pipeline
        </button>
      </div>

      <section className="tile run-head" data-tilt="">
        <div className="ident">
          <span className="kick">
            {run.sport} ingestion · {run.task_name ?? 'no TASK_NAME'}
          </span>
          <div className="title">
            <h1>{run.pipeline}</h1>
            <StatusPill state={PILL_STATE[run.state] ?? 'ok'} />
          </div>
          <p className="when">
            {dayDate(run.run_started_at)} · RUN_STARTED_AT {hhmmss(run.run_started_at)} to
            RUN_ENDED_AT {run.run_ended_at ? hhmmss(run.run_ended_at) : 'NULL'} · QUERY_ID{' '}
            <span className="mono">{run.query_id}</span>
          </p>
        </div>

        <VerdictPair taskState={run.task_state} dltStatus={run.dlt_status} variant={variant} />

        <p className="agree">
          {run.outcome_disagrees
            ? 'Verdicts disagree, and neither has been ruled out: '
            : 'Verdicts agree: '}
          <code>OUTCOME_DISAGREES = {bool(run.outcome_disagrees)}</code>{' '}
          <code>DLT_RECORD_MISSING = {bool(run.dlt_record_missing)}</code>
        </p>

        <AnnotationNote label="Annotation, two sources, never merged:">
          TASK_STATE and DLT_STATUS are independent, and this pair is rendered even when they agree.
          When OUTCOME_DISAGREES is true the pair itself is the finding; when DLT_RECORD_MISSING is
          true the right box renders hatched with a NULL, the worst failure class, because the run
          died before it could record itself.
        </AnnotationNote>
      </section>

      <div className="kpis five">
        <div className="kpi">
          <span className="l">Duration</span>
          <span className="v">{duration(run.duration_s) ?? 'NULL'}</span>
          <span className="s">
            STARTUP_OVERHEAD_S {run.startup_overhead_s ?? 'NULL'} · CONTAINER_SPAN_S{' '}
            {run.container_span_s ?? 'NULL'}
          </span>
        </div>
        <div className={run.rows_loaded ? 'kpi' : 'kpi bad'}>
          <span className="l">Rows loaded</span>
          <span className="v">{run.rows_loaded == null ? 'NULL' : compact(run.rows_loaded)}</span>
          <span className="s">
            {run.resources?.length
              ? `${run.resources.length} resource${run.resources.length === 1 ? '' : 's'}`
              : 'RESOURCES NULL'}
          </span>
        </div>
        <div className={(run.error_lines ?? 0) > 0 ? 'kpi bad' : 'kpi'}>
          <span className="l">Log lines</span>
          <span className="v">{run.log_lines == null ? 'NULL' : compact(run.log_lines)}</span>
          <span className="s">
            ERROR_LINES {num(run.error_lines)} · WARNING_LINES {num(run.warning_lines)}
          </span>
        </div>
        <div className="kpi">
          {/* A maximum never renders without the scrape count behind it: with one
              to four samples per run it is a floor on the peak, not the peak. */}
          <span className="l">CPU max / memory max</span>
          <span className="v">
            {run.cpu_cores_max == null ? 'NULL' : run.cpu_cores_max.toFixed(2)}
          </span>
          <span className="s">
            cores of CPU_CORES_LIMIT {run.cpu_cores_limit ?? 'NULL'} · MEM_BYTES_MAX{' '}
            {bytes(run.mem_bytes_max)} · CPU_SAMPLES {run.cpu_samples ?? 0}, MEM_SAMPLES{' '}
            {run.mem_samples ?? 0}
          </span>
        </div>
        <div className={(run.restarts ?? 0) > 0 ? 'kpi bad' : 'kpi'}>
          <span className="l">Restarts</span>
          <span className="v">{run.restarts ?? 'NULL'}</span>
          <span className="s">EXIT_STATUS {run.exit_status ?? 'NULL'}</span>
        </div>
      </div>

      <div className="grid cols-detail">
        <TileFrame
          title={`Where the ${run.duration_s ?? 'NULL'} seconds went`}
          meta="STARTUP_OVERHEAD_S against CONTAINER_SPAN_S"
        >
          <SegmentedDurationBar
            durationS={run.duration_s}
            startupOverheadS={run.startup_overhead_s}
            containerSpanS={run.container_span_s}
            failed={failed}
            size="labeled"
          />
        </TileFrame>

        <TileFrame
          title={`This slot, previous ${run.prior_runs.length} runs`}
          meta="oldest first"
          caption="Same states and same marks as the board and the heatmap; this run is the outlined box."
        >
          <MiniRunStrip
            slots={slots}
            currentAt={run.run_started_at}
            caption="oldest first · this run is outlined"
          />
        </TileFrame>
      </div>

      {run.error_text ? (
        <TileFrame
          title="ERROR_TEXT"
          meta={`resolved from ${run.error_provenance ?? 'an unrecorded source'}`}
          className="error-tile"
          caption="The view COALESCEs the dlt exception with TASK_HISTORY.ERROR_MESSAGE, so ERROR_TEXT never appears without saying which of the two it came from."
        >
          <pre>{run.error_text}</pre>
        </TileFrame>
      ) : null}

      <TileFrame title="Evidence" meta="logs, metrics and row counts for this QUERY_ID">
        <Tabs tabs={tabs} scope="run" />
      </TileFrame>

      <TileFrame title="Run facts" meta="V_PIPELINE_RUNS, one row">
        <Facts facts={runFacts(run)} />
      </TileFrame>

      <TileFrame title="How this page is built" className="note-tile" query={run.query}>
        <p>
          One row of DLT_DB.OPS.PIPELINE_RUNS read by QUERY_ID, with the logs, the metric samples
          and the per-table row counts fetched under that same id as each tab is opened. EXIT_STATUS
          reads NULL for a failure at infrastructure level and FAILED when the container itself
          exited nonzero, so it never explains a failure on its own: the reason always resolves
          through ERROR_TEXT.
        </p>
      </TileFrame>
    </div>
  )
}
