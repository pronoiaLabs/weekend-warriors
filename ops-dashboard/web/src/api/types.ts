/** Narrow mirrors of the FastAPI payloads, limited to what the UI reads today. */

export interface SportSummary {
  sport: string
  pipelines: number
}

export interface SportsPayload {
  sports: SportSummary[]
}

export type BlockKind = 'run' | 'missed' | 'upcoming'

/** Known block states. The API lowercases any TASK_STATE it does not classify,
    so the union stays open rather than lying about the wire format. */
export type BlockState =
  | 'succeeded'
  | 'failure'
  | 'missing'
  | 'missed'
  | 'upcoming'
  | (string & {})

/** Severity classes shared by card state, panel worst and badge kind. */
export type AnomalyKind = 'missing' | 'missed' | 'failure' | 'disagree' | 'ok'

export interface Block {
  kind: BlockKind
  state: BlockState
  pipeline: string
  at: string
  duration_s?: number | null
  rows_loaded?: number | null
  query_id?: string | null
  error_excerpt?: string | null
}

export interface Sublane {
  pipeline: string
  schedule: string
  cron: string
  not_scheduled_today: boolean
  next_fire: string
  last_duration_s: number | null
  last_rows_loaded: number | null
  blocks: Block[]
}

export interface BoardSport {
  sport: string
  blocks: Block[]
  sublanes: Sublane[]
}

export interface BoardWindow {
  start: string
  end: string
}

export interface Board {
  window: BoardWindow
  sports: BoardSport[]
}

export interface OverviewSummary {
  pipelines: number
  sports: number
  slots_today: number
  succeeded_today: number
  failed_today: number
  missing_today: number
  missed_today: number
  upcoming_today: number
}

export interface Badge {
  kind: AnomalyKind
  count: number
  window_days: number
  last_at?: string
}

export interface PipelineCard {
  pipeline: string
  state: AnomalyKind
  last_run: Block | null
  task_state: string | null
  dlt_status: string | null
  missed_slots_today: number
  badges: Badge[]
}

export interface SportPanel {
  sport: string
  pipelines: number
  worst: AnomalyKind
  missed_slots_today: number
  rows_today: number
  anomaly_count: number
  healthy_count: number
  cards: PipelineCard[]
}

export interface OverviewPayload {
  date: string
  now: string
  summary: OverviewSummary
  board: Board
  sports: SportPanel[]
}

export interface IncidentCounts {
  failure: number
  missing: number
  disagree: number
  missed: number
}

/** The header of /api/incidents on its own, for callers that only need totals. */
export interface IncidentCountsPayload {
  days: number
  now: string
  counts: IncidentCounts
}

/** Every incident kind except "ok", which is the absence of one. */
export type IncidentKind = 'failure' | 'missing' | 'disagree' | 'missed'

/** The run that followed this one on the same pipeline, when there is one. */
export interface NextOutcome {
  task_state: string | null
  at: string
}

/** An incident carried by a V_PIPELINE_RUNS row. */
export interface RunIncident {
  kind: 'failure' | 'missing' | 'disagree'
  sport: string
  pipeline: string
  at: string
  query_id: string | null
  duration_s: number | null
  rows_loaded: number | null
  load_id: string | null
  task_state: string | null
  dlt_status: string | null
  error_text: string | null
  error_provenance: string | null
  error_lines: number | null
  log_lines: number | null
  container_never_started: boolean | null
  next_outcome: NextOutcome | null
}

export interface SlotSample {
  at: string
  state: BlockState
}

/** An incident with no run row behind it: a cron slot that fired nothing. The
    fields a run would carry are absent rather than null-filled. */
export interface MissedIncident {
  kind: 'missed'
  sport: string
  pipeline: string
  at: string
  noticed: string
  query_id: null
  schedule: string
  slot_strip: SlotSample[]
}

export type Incident = RunIncident | MissedIncident

export interface IncidentsPayload extends IncidentCountsPayload {
  /** Newest first. `counts` covers the whole window regardless of any kind
      filter applied to this list. */
  incidents: Incident[]
}

/** One V_PIPELINE_RUNS row, every column, exactly as the detail endpoints
    return it. The detail pages label these with their uppercase column names,
    so the field names here are the labels. */
export interface RunRow {
  sport: string
  pipeline: string
  task_name: string | null
  query_id: string
  service_name: string | null
  compute_pool: string | null
  run_started_at: string
  run_ended_at: string | null
  duration_s: number | null
  container_span_s: number | null
  startup_overhead_s: number | null
  task_state: string | null
  dlt_status: string | null
  outcome_disagrees: boolean | null
  dlt_record_missing: boolean | null
  rows_loaded: number | null
  row_counts: Record<string, number> | null
  load_id: string | null
  /** A parsed VARIANT: the resource names this run loaded. */
  resources: string[] | null
  error_text: string | null
  exit_status: string | null
  log_lines: number | null
  error_lines: number | null
  warning_lines: number | null
  unparsed_lines: number | null
  /** Every metric row for the run, not the scrape count: CPU_SAMPLES and
      MEM_SAMPLES are the scrapes, and the two never share a label. */
  metric_samples: number | null
  cpu_cores_max: number | null
  cpu_samples: number | null
  cpu_cores_limit: number | null
  mem_bytes_max: number | null
  mem_samples: number | null
  mem_bytes_requested: number | null
  restarts: number | null
  telemetry_available: boolean | null
  container_never_started: boolean | null
  /** Derived by the API, not columns: the anomalies this row carries, the worst
      of them as a state, and which source ERROR_TEXT resolved from. */
  anomalies: AnomalyKind[]
  state: BlockState
  error_provenance: string | null
}

/** A heatmap day. `scheduled` is a future cron slot and `none` a day the cron
    never fires, neither of which is a run: both are unlinked. */
export type HeatState =
  | 'succeeded'
  | 'failure'
  | 'missing'
  | 'missed'
  | 'scheduled'
  | 'none'
  | (string & {})

export interface HeatCell {
  date: string
  state: HeatState
  query_id: string | null
}

export interface PipelineDetailPayload {
  pipeline: string
  sport: string
  schedule: string
  cron: string
  next_fire: string
  task_name: string | null
  compute_pool: string | null
  window_days: number
  succeeded: number
  runs_in_window: number
  median_duration_s: number | null
  last_success_at: string | null
  heatmap: HeatCell[]
  runs: RunRow[]
}

/** The same slot on previous days, oldest first as the API emits it. */
export interface PriorRun {
  query_id: string | null
  at: string
  state: BlockState
}

export interface RunDetailPayload extends RunRow {
  prev_row_counts: Record<string, number> | null
  prior_runs: PriorRun[]
}

export interface LogLine {
  event_ts: string
  severity: string | null
  logger_name: string | null
  container_name: string | null
  log_format: string | null
  message: string
}

export interface LogsPayload {
  query_id: string
  total_log_lines: number | null
  error_lines: number | null
  warning_lines: number | null
  lines: LogLine[]
}

export interface MetricPoint {
  at: string
  value: number | null
}

export interface MetricStrip {
  points: MetricPoint[]
  limit: number | null
  unit: string | null
}

export interface MetricSummary {
  samples: number
  max: number | null
  unit: string | null
  group: string | null
}

export interface MetricsPayload {
  query_id: string
  metric_samples: number | null
  cpu_samples: number | null
  mem_samples: number | null
  telemetry_available: boolean | null
  container_never_started: boolean | null
  node_instance_family: string | null
  strips: { cpu: MetricStrip; memory: MetricStrip }
  metrics: Record<string, MetricSummary>
}

export interface RowCountsPayload {
  query_id: string
  rows_loaded: number | null
  row_counts: Record<string, number> | null
  prev_row_counts: Record<string, number> | null
}
