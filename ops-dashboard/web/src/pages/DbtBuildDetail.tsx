import { useState } from 'react'
import { useParams } from 'react-router-dom'
import { fetchDbtBuild, fetchDbtBuildQueries, fetchDbtQueryOperators } from '../api/client.ts'
import type { DbtBuildRow, DbtLoadRow, DbtQueryOperator, DbtQueryRow } from '../api/types.ts'
import Crumbs from '../components/Crumbs.tsx'
import { DbtStateChip } from '../components/DbtStateChip.tsx'
import { Expander } from '../components/Expander.tsx'
import TileFrame from '../components/TileFrame.tsx'
import { useApi } from '../hooks/useApi.ts'
import { useBack } from '../hooks/useBack.ts'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import { bytes, compact, dayHhmm, duration, elapsedMs, hhmmss, num } from '../utils/format.ts'
import { leagueLabel } from '../utils/leagues.ts'
import '../styles/pages/build-detail.css'

const QUERY_LIMIT = 100

/** dbt node names arrive fully qualified, and the project name is the same on
    every row of every build, so it carries no information here. */
const NODE_PREFIX = /^[a-z_]+\.cortex_agent_lifecycle\./

// Operator statistics are free-form per operator type; these two are the ones
// worth reading first when they exist, and the rest keep their own order.
const STAT_RANK: Record<string, number> = { output_rows: 0, input_rows: 1 }

/** The placeholder for a value the build never recorded. */
const NONE = '·'

function shortNode(node: string | null): string {
  return node == null ? 'no node' : node.replace(NODE_PREFIX, '')
}

/** A build id is a UUID; the first block is enough to tell two builds apart in
    a crumb or a title, and the whole value stays in the fact grid. */
function shortId(id: string): string {
  return id.length > 8 ? id.slice(0, 8) : id
}

/** GET_QUERY_OPERATOR_STATS reports these as fractions of one; anything above
    one is already a percentage and is passed through rather than multiplied. */
function pct(value: number): string {
  return `${Math.round(value <= 1 ? value * 100 : value)}%`
}

function numberAt(source: Record<string, unknown> | null, key: string): number | null {
  const value = source?.[key]
  return typeof value === 'number' ? value : null
}

/** The dominant entries of the time breakdown, minus the overall share, which
    is rendered as its own column. */
function breakdownText(breakdown: Record<string, unknown> | null): string {
  if (!breakdown) return NONE
  const parts = Object.entries(breakdown)
    .flatMap(([key, value]) =>
      key !== 'overall_percentage' && typeof value === 'number' ? [[key, value] as const] : [],
    )
    .sort((left, right) => right[1] - left[1])
    .slice(0, 3)
    .map(([key, value]) => `${key} ${pct(value)}`)
  return parts.length > 0 ? parts.join(' · ') : NONE
}

/** Top-level numeric statistics only: the nested bags (io, pruning, network)
    are a level of detail this page deliberately does not go to. */
function statsText(statistics: Record<string, unknown> | null): string {
  if (!statistics) return NONE
  const parts = Object.entries(statistics)
    .flatMap(([key, value]) => (typeof value === 'number' ? [[key, value] as const] : []))
    .sort((left, right) => (STAT_RANK[left[0]] ?? 9) - (STAT_RANK[right[0]] ?? 9))
    .slice(0, 4)
    .map(([key, value]) => `${key} ${num(value)}`)
  return parts.length > 0 ? parts.join(' · ') : NONE
}

function operatorShare(operator: DbtQueryOperator): number {
  return numberAt(operator.execution_time_breakdown, 'overall_percentage') ?? 0
}

function startedAt(build: DbtBuildRow): string | null {
  return build.started_at ?? build.scheduled_time
}

/** The event-driven dbt build behind one DBT_BUILD_<SPORT> task run: what it
    was told to do, which dlt loads set it off, and every query it issued with
    its plan a click away. */
export default function DbtBuildDetail() {
  const { buildId = '' } = useParams()
  const search = useOpsSearch()
  const back = useBack({ pathname: '/builds', search })
  // No `now`: a build payload carries no clock, and the head tile below already
  // says when this one ran, so the shell's freshness pill is left alone.
  const res = useApi((signal) => fetchDbtBuild(buildId, signal), [buildId])

  const data = res.data
  if (!data) {
    return (
      <div className="page page-build">
        <Crumbs
          items={[
            { label: 'Builds', to: { pathname: '/builds', search } },
            { label: res.error ? 'No such build' : shortId(buildId) },
          ]}
        />
        <div className="page-head">
          <h1>{res.error ? 'No such build' : 'Loading...'}</h1>
          <p className="lede">
            {res.error ? `${res.error}. Pick a build from the builds page.` : `Reading build ${shortId(buildId)}.`}
          </p>
        </div>
      </div>
    )
  }

  const { build, loads } = data
  const at = startedAt(build)
  const failedQueries = build.n_failed_queries ?? 0

  return (
    <div className="page page-build">
      <div className="crumb-row">
        <Crumbs
          items={[
            { label: 'Builds', to: { pathname: '/builds', search } },
            { label: `${build.sport} build ${shortId(build.build_id ?? build.run_query_id)}` },
          ]}
        />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to builds
        </button>
      </div>

      <section className="tile build-head" data-tilt="">
        <div className="ident">
          <span className="kick">
            {build.task_name} · {build.environment ?? 'no ENVIRONMENT'}
          </span>
          <h1>
            {leagueLabel(build.sport)} <span className="at">{build.args}</span>
          </h1>
          <p className="lede">
            {build.project_fqn ?? 'No PROJECT_FQN recorded'}.{' '}
            {at ? `Started ${dayHhmm(at)}` : 'No start time recorded'},{' '}
            {build.completed_time ? `finished ${hhmmss(build.completed_time)}` : 'no completion time'}.
          </p>
        </div>
        <DbtStateChip state={build.state} />
      </section>

      <div className="kpis four">
        <div className="kpi">
          <span className="l">Duration</span>
          <span className="v">{duration(build.duration_s) ?? NONE}</span>
          <span className="s">{at ? `started ${hhmmss(at)}` : 'no STARTED_AT'}</span>
        </div>
        <div className={`kpi ${failedQueries > 0 ? 'bad' : ''}`}>
          <span className="l">Queries</span>
          <span className="v">{build.n_queries == null ? NONE : compact(build.n_queries)}</span>
          <span className="s">
            {failedQueries > 0 ? `${num(failedQueries)} failed` : 'none failed'}
            {build.n_node_queries == null ? '' : ` · ${num(build.n_node_queries)} on a node`}
          </span>
        </div>
        <div className="kpi">
          <span className="l">Loads drained</span>
          <span className="v">{build.drained_loads == null ? NONE : num(build.drained_loads)}</span>
          <span className="s">from the RAW._DLT_LOADS stream</span>
        </div>
        <div className="kpi">
          <span className="l">Bytes scanned</span>
          <span className="v">{bytes(build.sum_bytes_scanned)}</span>
          <span className="s">
            {build.sum_rows_produced == null
              ? 'no rows recorded'
              : `${num(build.sum_rows_produced)} rows produced`}
          </span>
        </div>
      </div>

      {build.error_message && (
        <TileFrame title="ERROR_MESSAGE" meta="from the DBT_BUILD task run" className="error-tile">
          {build.error_message}
        </TileFrame>
      )}

      <div className="grid cols-detail">
        <TileFrame title="Build facts" meta="one execution, every column" className="facts-tile">
          <Facts facts={buildFacts(build)} />
        </TileFrame>

        <TileFrame
          title="Triggering loads"
          meta={`${loads.length} drained`}
          className="table-tile"
          caption="A load row is a successful dlt load the stream carried into this build; SP_DBT_BUILD drains them before it runs."
        >
          <LoadsTable loads={loads} />
        </TileFrame>
      </div>

      <TileFrame
        title="Queries"
        meta={`slowest first · at most ${QUERY_LIMIT}`}
        className="table-tile"
        caption="Expand a row for the query's operator breakdown, fetched on demand from the captured GET_QUERY_OPERATOR_STATS rows."
      >
        {build.build_id ? (
          <QueriesTable buildId={build.build_id} />
        ) : (
          <p className="hint">
            BUILD_ID is NULL on this row, so no query history can be attributed to it.
          </p>
        )}
      </TileFrame>

      <TileFrame title="How this page is built" className="note-tile" query={data.query}>
        <p>
          One row of DLT_DB.OPS.V_DBT_RUNS with its audit rows and its tagged queries. A build
          appears here only when the trigger fired: DBT_BUILD_&lt;SPORT&gt; has no schedule and runs
          on SYSTEM$STREAM_HAS_DATA, so a quiet day is an empty page rather than a failure. The
          operator statistics behind each query are captured after the build by SP_DBT_HARVEST, so a
          query that just ran can have nothing to expand yet.
        </p>
      </TileFrame>
    </div>
  )
}

interface FactSpec {
  k: string
  v: string
  bad?: boolean
}

function Facts({ facts }: { facts: FactSpec[] }) {
  return (
    <div className="facts">
      {facts.map((fact) => (
        <div className="fact" key={fact.k}>
          <div className="k">{fact.k}</div>
          <div className={fact.bad ? 'v bad' : 'v'}>{fact.v}</div>
        </div>
      ))}
    </div>
  )
}

/** Every column of the row, labelled with its own uppercase column name, the
    same contract the run detail page keeps: the page and a `SELECT *` read the
    same. */
function buildFacts(build: DbtBuildRow): FactSpec[] {
  const failedQueries = build.n_failed_queries ?? 0
  return [
    { k: 'SPORT', v: build.sport },
    { k: 'STATE', v: build.state, bad: build.state.toUpperCase() !== 'SUCCESS' },
    { k: 'ARGS', v: build.args },
    { k: 'ENVIRONMENT', v: build.environment ?? 'NULL' },
    { k: 'PROJECT_FQN', v: build.project_fqn ?? 'NULL' },
    { k: 'TASK_NAME', v: build.task_name },
    { k: 'BUILD_ID', v: build.build_id ?? 'NULL' },
    { k: 'RUN_QUERY_ID', v: build.run_query_id },
    { k: 'EXEC_QUERY_ID', v: build.exec_query_id ?? 'NULL' },
    { k: 'DRAINED_LOADS', v: build.drained_loads == null ? 'NULL' : num(build.drained_loads) },
    { k: 'DURATION_S', v: String(build.duration_s ?? 'NULL') },
    { k: 'SCHEDULED_TIME', v: build.scheduled_time ? hhmmss(build.scheduled_time) : 'NULL' },
    { k: 'STARTED_AT', v: build.started_at ? hhmmss(build.started_at) : 'NULL' },
    { k: 'COMPLETED_TIME', v: build.completed_time ? hhmmss(build.completed_time) : 'NULL' },
    { k: 'N_QUERIES', v: build.n_queries == null ? 'NULL' : num(build.n_queries) },
    {
      k: 'N_FAILED_QUERIES',
      v: build.n_failed_queries == null ? 'NULL' : num(build.n_failed_queries),
      bad: failedQueries > 0,
    },
    { k: 'N_NODE_QUERIES', v: build.n_node_queries == null ? 'NULL' : num(build.n_node_queries) },
    { k: 'SUM_ELAPSED_MS', v: elapsedMs(build.sum_elapsed_ms) },
    { k: 'MAX_ELAPSED_MS', v: elapsedMs(build.max_elapsed_ms) },
    { k: 'SUM_BYTES_SCANNED', v: bytes(build.sum_bytes_scanned) },
    {
      k: 'SUM_ROWS_PRODUCED',
      v: build.sum_rows_produced == null ? 'NULL' : num(build.sum_rows_produced),
    },
  ]
}

function LoadsTable({ loads }: { loads: DbtLoadRow[] }) {
  if (loads.length === 0) {
    return (
      <p className="hint">
        No load rows recorded against this build: the audit table has nothing for it, which is what
        a manual invocation looks like.
      </p>
    )
  }
  return (
    <table className="standings">
      <thead>
        <tr>
          <th>LOAD_ID</th>
          <th>PIPELINE</th>
          <th className="num">STATUS</th>
          <th>INSERTED_AT</th>
          <th>DRAINED_AT</th>
        </tr>
      </thead>
      <tbody>
        {loads.map((load) => (
          <tr key={load.load_id}>
            <td className="mono">{load.load_id}</td>
            <td className="pname">{load.pipeline}</td>
            <td className="num">{load.status}</td>
            <td>{dayHhmm(load.inserted_at)}</td>
            <td>{dayHhmm(load.drained_at)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function QueriesTable({ buildId }: { buildId: string }) {
  const res = useApi(
    (signal) => fetchDbtBuildQueries(buildId, QUERY_LIMIT, signal),
    [buildId],
  )
  // The open row is state rather than a URL param: it is a reading aid inside
  // one table, not a view worth sharing.
  const [openQuery, setOpenQuery] = useState<string | null>(null)

  if (!res.data) {
    return <p className={res.error ? 'hint bad' : 'hint'}>{res.error ?? 'Loading queries...'}</p>
  }
  if (res.data.queries.length === 0) {
    return <p className="hint">No queries recorded against this build.</p>
  }

  return (
    <table className="standings">
      <thead>
        <tr>
          <th aria-label="Expand" />
          <th>Node</th>
          <th>QUERY_TYPE</th>
          <th>EXECUTION_STATUS</th>
          <th className="num">TOTAL_ELAPSED_TIME</th>
          <th className="num">COMPILATION_TIME</th>
          <th className="num">QUEUED_OVERLOAD_TIME</th>
          <th className="num">BYTES_SCANNED</th>
          <th className="num">ROWS_PRODUCED</th>
          <th>WAREHOUSE_NAME</th>
        </tr>
      </thead>
      <tbody>
        {res.data.queries.map((query) => (
          <QueryRow
            key={query.query_id}
            query={query}
            open={openQuery === query.query_id}
            onToggle={() =>
              setOpenQuery((current) => (current === query.query_id ? null : query.query_id))
            }
          />
        ))}
      </tbody>
    </table>
  )
}

function QueryRow({
  query,
  open,
  onToggle,
}: {
  query: DbtQueryRow
  open: boolean
  onToggle: () => void
}) {
  const failed = query.execution_status.toUpperCase() !== 'SUCCESS'
  const classes = ['qrow', failed ? 'bad' : '', query.stats_captured ? 'row-link' : '']
    .filter(Boolean)
    .join(' ')

  return (
    <>
      {/* Clicking the row is a mouse convenience; the caret is the accessible
          control, and a query without captured stats has nothing to open. */}
      <tr className={classes} onClick={query.stats_captured ? onToggle : undefined}>
        <td className="caretcell">
          {query.stats_captured ? (
            <Expander
              open={open}
              onToggle={onToggle}
              label={`${open ? 'Collapse' : 'Expand'} the operator breakdown for ${shortNode(query.node)}`}
            />
          ) : (
            <span className="muted" title="No operator stats captured for this query">
              {NONE}
            </span>
          )}
        </td>
        <td>
          <div className="qnode" title={query.node ?? undefined}>
            {shortNode(query.node)}
          </div>
          {query.error_message ? (
            <div className="qerr" title={query.error_message}>
              {query.error_message}
            </div>
          ) : null}
        </td>
        <td>{query.query_type}</td>
        <td className={failed ? 'fail' : undefined}>{query.execution_status}</td>
        <td className="num">{elapsedMs(query.total_elapsed_time)}</td>
        <td className="num">{elapsedMs(query.compilation_time)}</td>
        <td className="num">{elapsedMs(query.queued_overload_time)}</td>
        <td className="num">{bytes(query.bytes_scanned)}</td>
        <td className="num">{query.rows_produced == null ? NONE : num(query.rows_produced)}</td>
        <td>{query.warehouse_name}</td>
      </tr>
      {open ? (
        <tr className="opsrow">
          <td colSpan={10}>
            <OperatorTable queryId={query.query_id} />
          </td>
        </tr>
      ) : null}
    </>
  )
}

/** The query's plan, fetched only when its row is opened: one build can hold a
    hundred queries and the operator stats are the heaviest thing on the page. */
function OperatorTable({ queryId }: { queryId: string }) {
  const res = useApi((signal) => fetchDbtQueryOperators(queryId, signal), [queryId])

  if (!res.data) {
    return (
      <p className={res.error ? 'hint bad' : 'hint'}>
        {res.error ? `Could not load operator stats: ${res.error}` : 'Loading operator stats...'}
      </p>
    )
  }
  if (res.data.operators.length === 0) {
    return <p className="hint">GET_QUERY_OPERATOR_STATS returned no rows for this query.</p>
  }

  // Costliest operator first: the plan order is already implied by the step and
  // operator ids, which stay on every row.
  const operators = [...res.data.operators].sort(
    (left, right) => operatorShare(right) - operatorShare(left),
  )

  return (
    <>
      <p className="hint">
        GET_QUERY_OPERATOR_STATS · {operators.length} operators · share is
        EXECUTION_TIME_BREAKDOWN.overall_percentage
      </p>
      <table className="standings">
        <thead>
          <tr>
            <th>STEP.OP</th>
            <th>OPERATOR_TYPE</th>
            <th className="num">Share</th>
            <th>Time breakdown</th>
            <th>Statistics</th>
            <th>Parents</th>
          </tr>
        </thead>
        <tbody>
          {operators.map((operator) => (
            <tr key={`${operator.step_id}.${operator.operator_id}`}>
              <td>
                {operator.step_id}.{operator.operator_id}
              </td>
              <td>{operator.operator_type}</td>
              <td className="num">
                {operator.execution_time_breakdown == null ? NONE : pct(operatorShare(operator))}
              </td>
              <td>{breakdownText(operator.execution_time_breakdown)}</td>
              <td>{statsText(operator.operator_statistics)}</td>
              <td>{operator.parent_operators?.join(', ') || NONE}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  )
}
