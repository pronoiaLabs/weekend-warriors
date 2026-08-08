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

/** Only the header of /api/incidents; the feed itself lands in a later phase. */
export interface IncidentCountsPayload {
  days: number
  now: string
  counts: IncidentCounts
}
