import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { fetchDbtBuild, fetchDbtBuildQueries, fetchDbtQueryOperators } from '../api/client.ts'
import type {
  DbtBuildDetailPayload,
  DbtBuildRow,
  DbtBuildQueriesPayload,
  DbtQueryOperator,
  DbtQueryOperatorsPayload,
  DbtQueryRow,
} from '../api/types.ts'
import { DbtStateChip } from '../components/DbtStateChip.tsx'
import { Expander } from '../components/Expander.tsx'
import { EmptyState } from '../components/QuietNote.tsx'
import { SectionHead } from '../components/SectionHead.tsx'
import { Chrome } from '../components/slate/Chrome.tsx'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { bytes, dayHhmm, duration, elapsedMs, hhmmss, num } from '../utils/format.ts'

const QUERY_LIMIT = 100

/** dbt node names arrive fully qualified, and the project name is the same on
    every row of every build, so it carries no information here. */
const NODE_PREFIX = /^[a-z_]+\.cortex_agent_lifecycle\./

// Operator statistics are free-form per operator type; these two are the ones
// worth reading first when they exist, and the rest keep their own order.
const STAT_RANK: Record<string, number> = { output_rows: 0, input_rows: 1 }

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function shortNode(node: string | null): string {
  return node == null ? 'no node' : node.replace(NODE_PREFIX, '')
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
  if (!breakdown) return '·'
  const parts = Object.entries(breakdown)
    .flatMap(([key, value]) =>
      key !== 'overall_percentage' && typeof value === 'number' ? [[key, value] as const] : [],
    )
    .sort((left, right) => right[1] - left[1])
    .slice(0, 3)
    .map(([key, value]) => `${key} ${pct(value)}`)
  return parts.length > 0 ? parts.join(' · ') : '·'
}

/** Top-level numeric statistics only: the nested bags (io, pruning, network)
    are a level of detail this page deliberately does not go to. */
function statsText(statistics: Record<string, unknown> | null): string {
  if (!statistics) return '·'
  const parts = Object.entries(statistics)
    .flatMap(([key, value]) => (typeof value === 'number' ? [[key, value] as const] : []))
    .sort((left, right) => (STAT_RANK[left[0]] ?? 9) - (STAT_RANK[right[0]] ?? 9))
    .slice(0, 4)
    .map(([key, value]) => `${key} ${num(value)}`)
  return parts.length > 0 ? parts.join(' · ') : '·'
}

function operatorShare(operator: DbtQueryOperator): number {
  return numberAt(operator.execution_time_breakdown, 'overall_percentage') ?? 0
}

interface FactSpec {
  k: string
  v: string
  bad?: boolean
}

function Facts({ facts }: { facts: FactSpec[] }) {
  return (
    <div className="runfacts">
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
    { k: 'SCHEDULED_TIME', v: build.scheduled_time ? `${hhmmss(build.scheduled_time)} UTC` : 'NULL' },
    { k: 'STARTED_AT', v: build.started_at ? `${hhmmss(build.started_at)} UTC` : 'NULL' },
    {
      k: 'COMPLETED_TIME',
      v: build.completed_time ? `${hhmmss(build.completed_time)} UTC` : 'NULL',
    },
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

function OperatorTable({ queryId }: { queryId: string }) {
  const [payload, setPayload] = useState<DbtQueryOperatorsPayload | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const control = new AbortController()
    fetchDbtQueryOperators(queryId, control.signal)
      .then(setPayload)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [queryId])

  if (error) return <p className="pane-src bad">Could not load operator stats: {error}</p>
  if (!payload) return <p className="pane-src">Loading operator stats...</p>
  if (payload.operators.length === 0) {
    return <p className="pane-src">GET_QUERY_OPERATOR_STATS returned no rows for this query.</p>
  }

  // Costliest operator first: the plan order is already implied by the step and
  // operator ids, which stay on every row.
  const operators = [...payload.operators].sort(
    (left, right) => operatorShare(right) - operatorShare(left),
  )

  return (
    <>
      <div className="pane-src">
        GET_QUERY_OPERATOR_STATS · {payload.operators.length} operators · share is
        EXECUTION_TIME_BREAKDOWN.overall_percentage
      </div>
      <table className="data ops-table">
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
                {operator.execution_time_breakdown == null ? '·' : pct(operatorShare(operator))}
              </td>
              <td>{breakdownText(operator.execution_time_breakdown)}</td>
              <td>{statsText(operator.operator_statistics)}</td>
              <td>{operator.parent_operators?.join(', ') || '·'}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  )
}

interface QueryRowProps {
  query: DbtQueryRow
  open: boolean
  onToggle: () => void
}

function QueryRow({ query, open, onToggle }: QueryRowProps) {
  const failed = query.execution_status.toUpperCase() !== 'SUCCESS'

  return (
    <>
      {/* Clicking the row is a mouse convenience; the caret is the accessible
          control, and a query without captured stats has nothing to open. */}
      <tr className={failed ? 'qrow bad' : 'qrow'} onClick={query.stats_captured ? onToggle : undefined}>
        <td className="caretcell">
          {query.stats_captured ? (
            <Expander
              open={open}
              onToggle={onToggle}
              label={`${open ? 'Collapse' : 'Expand'} the operator breakdown for ${shortNode(
                query.node,
              )}`}
            />
          ) : (
            <span className="muted" title="No operator stats captured for this query">
              ·
            </span>
          )}
        </td>
        <td>
          {shortNode(query.node)}
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
        <td className="num">{query.rows_produced == null ? '·' : num(query.rows_produced)}</td>
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

function QueriesPane({ buildId }: { buildId: string }) {
  const [payload, setPayload] = useState<DbtBuildQueriesPayload | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [openQuery, setOpenQuery] = useState<string | null>(null)

  useEffect(() => {
    const control = new AbortController()
    setPayload(null)
    setError(null)
    setOpenQuery(null)
    fetchDbtBuildQueries(buildId, QUERY_LIMIT, control.signal)
      .then(setPayload)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [buildId])

  if (error) return <p className="load-error">Could not load the build's queries: {error}</p>
  if (!payload) return <p className="loading">Loading queries...</p>
  if (payload.queries.length === 0) {
    return <p className="loading">No queries recorded against this build.</p>
  }

  return (
    <div className="table-scroll">
      <table className="pipes-table dbt-table">
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
          {payload.queries.map((query) => (
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
    </div>
  )
}

export default function DbtBuildDetail() {
  const { buildId = '' } = useParams()
  const { search } = useSportFilter()
  const [payload, setPayload] = useState<DbtBuildDetailPayload | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const control = new AbortController()
    setPayload(null)
    setError(null)
    fetchDbtBuild(buildId, control.signal)
      .then(setPayload)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [buildId])

  if (error) {
    return (
      <>
        <Chrome />
        <main className="wrap detail">
          <EmptyState message="Could not load this dbt build" detail={error} bad />
        </main>
      </>
    )
  }

  if (!payload) {
    return (
      <>
        <Chrome />
        <main className="wrap detail">
          <EmptyState message="Loading dbt build" detail={buildId} />
        </main>
      </>
    )
  }

  const { build, loads } = payload
  const at = build.started_at ?? build.scheduled_time

  return (
    <>
      {/* No `now`: a build payload has no clock, and the header below already
          says when this one ran. */}
      <Chrome />
      <main className="wrap detail">
        <div className="crumb">
          <Link to={{ pathname: '/', search }}>Dashboard</Link> /{' '}
          <Link to={{ pathname: '/builds', search }}>builds</Link> /{' '}
          {at ? `build ${dayHhmm(at)}` : 'build'}
        </div>

        <header className="runhead">
          <h1>
            {build.sport} <span className="dim">{build.args}</span>
          </h1>
          <span className="when">
            {at ? `STARTED_AT ${hhmmss(at)}` : 'no STARTED_AT'} to{' '}
            {build.completed_time ? `COMPLETED_TIME ${hhmmss(build.completed_time)}` : 'NULL'} UTC ·{' '}
            {duration(build.duration_s) ?? 'no DURATION_S'}
          </span>
        </header>

        <div className="dbt-head">
          <DbtStateChip state={build.state} />
          <span>ENVIRONMENT {build.environment ?? 'NULL'}</span>
          <span>DRAINED_LOADS {build.drained_loads == null ? 'NULL' : num(build.drained_loads)}</span>
          <span>
            {build.n_queries == null ? 'no' : num(build.n_queries)} queries
            {(build.n_failed_queries ?? 0) > 0 ? (
              <b className="fail"> · {num(build.n_failed_queries)} failed</b>
            ) : null}
          </span>
        </div>

        {build.error_message ? (
          <>
            <SectionHead title="ERROR_MESSAGE" count="from the DBT_BUILD task run" />
            <div className="errbox">{build.error_message}</div>
          </>
        ) : null}

        <SectionHead title="Build facts" count="one execution, every column" />
        <Facts facts={buildFacts(build)} />

        <SectionHead
          title="Triggering loads"
          count={`${loads.length} drained from the RAW._DLT_LOADS stream`}
        />
        {loads.length === 0 ? (
          <p className="pane-src">
            No load rows recorded against this build: the audit table has nothing for it, which is
            what a manual invocation looks like.
          </p>
        ) : (
          <div className="table-scroll">
            <table className="data">
              <thead>
                <tr>
                  <th>LOAD_ID</th>
                  <th>PIPELINE</th>
                  <th>STATUS</th>
                  <th>INSERTED_AT</th>
                  <th>DRAINED_AT</th>
                </tr>
              </thead>
              <tbody>
                {loads.map((load) => (
                  <tr key={load.load_id}>
                    <td>{load.load_id}</td>
                    <td>{load.pipeline}</td>
                    <td>{load.status}</td>
                    <td>{dayHhmm(load.inserted_at)} UTC</td>
                    <td>{dayHhmm(load.drained_at)} UTC</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <SectionHead
          title="Queries"
          count="slowest first · expand a row for its operator breakdown"
        />
        {build.build_id ? (
          <QueriesPane buildId={build.build_id} />
        ) : (
          <p className="pane-src">
            BUILD_ID is NULL on this row, so no query history can be attributed to it.
          </p>
        )}

        <p className="foot">
          A build appears here only when the trigger fired: DBT_BUILD_&lt;SPORT&gt; has no schedule
          and runs on SYSTEM$STREAM_HAS_DATA, so a quiet day is an empty page rather than a failure.
          · <Link to={{ pathname: '/dbt', search }}>Back to dbt builds</Link> ·{' '}
          <Link to={{ pathname: '/', search }}>Overview</Link>
        </p>
      </main>
    </>
  )
}
