import type { Cell, Kind, SheetColumn } from '../api/sports/types.ts'
import { fmt } from './format.ts'

/** Pure helpers for the Explorer grid: cell formatting by kind, column stats,
    a pivot over the loaded rows, and the TSV the copy button writes. Nothing
    here fetches; the rows are whatever page the API returned. */

export type Row = Record<string, Cell>

export function isNumeric(kind: Kind): boolean {
  return kind === 'integer' || kind === 'number'
}

export function formatCell(value: Cell, kind: Kind): string {
  if (value === null || value === undefined) return ''
  if (kind === 'boolean') return value ? 'true' : 'false'
  // integers are seasons, weeks, counts and yards: no thousands grouping, so 2025 reads as a year
  if (kind === 'integer') return String(Math.round(Number(value)))
  if (kind === 'number') {
    const n = Number(value)
    return Number.isInteger(n) ? fmt(n, 0) : fmt(n, Math.abs(n) < 10 ? 2 : 1)
  }
  if (kind === 'datetime') return String(value).replace('T', ' ').slice(0, 16)
  return String(value)
}

export interface Stats {
  count: number
  nulls: number
  sum: number
  avg: number
  min: number
  max: number
}

export function stats(rows: Row[], column: string): Stats {
  const values = rows.map((r) => r[column]).filter((v): v is number => typeof v === 'number')
  const nulls = rows.length - values.length
  if (values.length === 0) return { count: 0, nulls, sum: 0, avg: 0, min: 0, max: 0 }
  const sum = values.reduce((a, b) => a + b, 0)
  return { count: values.length, nulls, sum, avg: sum / values.length, min: Math.min(...values), max: Math.max(...values) }
}

export type Agg = 'sum' | 'avg' | 'count' | 'min' | 'max'
export const AGGS: Agg[] = ['sum', 'avg', 'count', 'min', 'max']

export interface PivotRow {
  key: string
  rows: number
  value: number
}

/** Group the rows by one column and aggregate another; sorted by the aggregate, largest first. */
export function pivot(rows: Row[], by: string, column: string, agg: Agg): PivotRow[] {
  const groups = new Map<string, number[]>()
  const counts = new Map<string, number>()
  for (const r of rows) {
    const key = r[by] === null || r[by] === undefined ? '(null)' : String(r[by])
    counts.set(key, (counts.get(key) ?? 0) + 1)
    const v = r[column]
    if (typeof v === 'number') groups.set(key, [...(groups.get(key) ?? []), v])
    else if (!groups.has(key)) groups.set(key, [])
  }
  const out: PivotRow[] = []
  for (const [key, values] of groups) {
    let value = 0
    if (agg === 'count') value = counts.get(key) ?? 0
    else if (values.length) {
      const sum = values.reduce((a, b) => a + b, 0)
      value = agg === 'sum' ? sum : agg === 'avg' ? sum / values.length : agg === 'min' ? Math.min(...values) : Math.max(...values)
    }
    out.push({ key, rows: counts.get(key) ?? 0, value })
  }
  return out.sort((a, b) => b.value - a.value || a.key.localeCompare(b.key))
}

export function tsv(rows: Row[], columns: SheetColumn[]): string {
  const head = columns.map((c) => c.name).join('\t')
  const body = rows.map((r) => columns.map((c) => (r[c.name] === null || r[c.name] === undefined ? '' : String(r[c.name]))).join('\t'))
  return [head, ...body].join('\n')
}

/** Columns worth a filter chip row: low-cardinality keys the sheets share. */
export const FILTERABLE = ['season', 'season_type', 'week', 'team', 'position', 'position_group', 'vendor', 'feed', 'market_type', 'is_home', 'result', 'team_result'] as const

/** Columns that are identity or calendar, never the number to total. */
export const NOT_A_MEASURE = ['season', 'week', 'game_id', 'player_id', 'team_id', 'snapshot_number', 'snapshots_before_kickoff'] as const

/** The column the stats tile opens on: the sort column when it is a measure, else the first measure. */
export function defaultMeasure(columns: SheetColumn[], order: string): string | null {
  const measures = columns.filter((c) => isNumeric(c.kind) && !(NOT_A_MEASURE as readonly string[]).includes(c.name))
  if (measures.some((c) => c.name === order)) return order
  return measures[0]?.name ?? columns.find((c) => isNumeric(c.kind))?.name ?? null
}

/** Distinct values of a column in the loaded rows, in a sensible order. */
export function distinct(rows: Row[], column: string, kind: Kind): string[] {
  const seen = new Set<string>()
  for (const r of rows) {
    const v = r[column]
    if (v !== null && v !== undefined) seen.add(String(v))
  }
  const values = [...seen]
  if (isNumeric(kind)) return values.sort((a, b) => Number(a) - Number(b))
  return values.sort()
}
