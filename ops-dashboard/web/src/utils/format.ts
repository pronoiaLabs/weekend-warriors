/** Times display in the viewer's local timezone, 12-hour am/pm, with no zone
    label: the dashboard reads on the wall clock. The exception is bare
    calendar dates (YYYY-MM-DD day identifiers from the API): those are
    anchored at UTC midnight so "2026-08-15" never renders as Friday in a
    negative-offset zone. Timestamps convert; day names for day keys do not. */

const HHMM = new Intl.DateTimeFormat('en-US', {
  hour: 'numeric',
  minute: '2-digit',
  hour12: true,
})

const HHMMSS = new Intl.DateTimeFormat('en-US', {
  hour: 'numeric',
  minute: '2-digit',
  second: '2-digit',
  hour12: true,
})

/** Local-zone formatters, for timestamps. */
const WEEKDAY_LOCAL = new Intl.DateTimeFormat('en-US', { weekday: 'short' })
const MONTH_DAY_LOCAL = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' })
/** en-CA renders "2026-08-11"; sliced for full or MM-DD forms. */
const DATE_LOCAL = new Intl.DateTimeFormat('en-CA', {
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
})

/** UTC-anchored formatters, ONLY for bare YYYY-MM-DD day keys. */
const WEEKDAY_UTC = new Intl.DateTimeFormat('en-US', { weekday: 'short', timeZone: 'UTC' })
const WEEKDAY_LONG_UTC = new Intl.DateTimeFormat('en-US', { weekday: 'long', timeZone: 'UTC' })
const MONTH_DAY_YEAR_UTC = new Intl.DateTimeFormat('en-US', {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
  timeZone: 'UTC',
})

export function hhmm(iso: string): string {
  return HHMM.format(new Date(iso))
}

export function weekday(iso: string): string {
  return WEEKDAY_LOCAL.format(new Date(iso))
}

/** "Tue 08-11 1:00 PM", the shape the wireframe uses for a next fire. */
export function dayHhmm(iso: string): string {
  const at = new Date(iso)
  return `${WEEKDAY_LOCAL.format(at)} ${DATE_LOCAL.format(at).slice(5)} ${HHMM.format(at)}`
}

/** "AUG 7", used inside anomaly badges. */
export function shortDate(iso: string): string {
  return MONTH_DAY_LOCAL.format(new Date(iso)).toUpperCase()
}

/** "Saturday 2026-08-08" from a bare YYYY-MM-DD. */
export function longDay(isoDate: string): string {
  return `${WEEKDAY_LONG_UTC.format(new Date(`${isoDate}T00:00:00Z`))} ${isoDate}`
}

/** "Saturday, Aug 8 2026" from a bare YYYY-MM-DD, the incident feed day header. */
export function longDayTitle(isoDate: string): string {
  const at = new Date(`${isoDate}T00:00:00Z`)
  return `${WEEKDAY_LONG_UTC.format(at)}, ${MONTH_DAY_YEAR_UTC.format(at).replace(',', '')}`
}

export function num(value: number | null | undefined): string {
  return value == null ? '0' : value.toLocaleString('en-US')
}

export function duration(seconds: number | null | undefined): string | null {
  return seconds == null ? null : `${seconds} s`
}

/** Query timings arrive in milliseconds while duration() speaks seconds, so
    anything under a second stays in milliseconds rather than rounding to "0 s"
    and reading as free. */
export function elapsedMs(value: number | null | undefined): string {
  if (value == null) return 'NULL'
  if (value < 1000) return `${Math.round(value)} ms`
  return duration(Math.round(value / 1000)) ?? 'NULL'
}

/** "8:14:23 PM", the log table's timestamp. Milliseconds are dropped: two
    lines of the same second are already adjacent in EVENT_TS order. */
export function hhmmss(iso: string): string {
  return HHMMSS.format(new Date(iso))
}

/** "Sat 2026-08-08", the run detail header's day, in the viewer's zone. */
export function dayDate(iso: string): string {
  const at = new Date(iso)
  return `${WEEKDAY_LOCAL.format(at)} ${DATE_LOCAL.format(at)}`
}

/** "Mo 27", one heatmap cell's label, from a bare YYYY-MM-DD. */
export function dayShort(isoDate: string): string {
  const at = new Date(`${isoDate}T00:00:00Z`)
  return `${WEEKDAY_UTC.format(at).slice(0, 2)} ${isoDate.slice(8, 10)}`
}

/** Cron (UTC, as the Tasks are scheduled) to local prose: "daily 6:00 PM" or
    "weekly Mon 9:00 PM". The API ships the raw cron and the conversion
    happens here because only the browser knows the viewer's zone -- and a
    weekly slot can land on a DIFFERENT local weekday than its UTC one.

    Anchored on today's date so the current DST offset applies. Only the
    shapes the registry uses (fixed minute/hour, * or single day-of-week);
    anything else falls back to the raw cron string. */
export function cronProse(cron: string): string {
  const parts = cron.trim().split(/\s+/)
  if (parts.length !== 5) return cron
  const [minute, hour, dom, month, dow] = parts
  if (!/^\d+$/.test(minute) || !/^\d+$/.test(hour) || dom !== '*' || month !== '*') return cron
  const now = new Date()
  const at = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), +hour, +minute),
  )
  if (dow === '*') return `daily ${HHMM.format(at)}`
  if (!/^\d+$/.test(dow)) return cron
  at.setUTCDate(at.getUTCDate() + ((+dow % 7) - at.getUTCDay()))
  return `weekly ${WEEKDAY_LOCAL.format(at)} ${HHMM.format(at)}`
}

/** Relative age against a timestamp taken from the payload. The browser clock
    is never the reference: a stale tab would otherwise age the page by itself. */
export function relativeTo(at: string, reference: string): string {
  const minutes = Math.max(0, Math.round((Date.parse(reference) - Date.parse(at)) / 60000))
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h ago`
  const days = Math.floor(hours / 24)
  return days === 1 ? 'yesterday' : `${days} days ago`
}

const KIB = 1024

/** Bytes at the unit the wireframe quotes: MiB for a container's usage, GiB
    once it passes a gibibyte. */
export function bytes(value: number | null | undefined): string {
  if (value == null) return 'NULL'
  if (value >= KIB ** 3) return `${(value / KIB ** 3).toFixed(2)} GiB`
  if (value >= KIB ** 2) return `${Math.round(value / KIB ** 2)} MiB`
  if (value >= KIB) return `${Math.round(value / KIB)} KiB`
  return `${value} B`
}

export function cores(value: number | null | undefined): string {
  return value == null ? 'NULL' : `${value.toFixed(2)} cores`
}

/** One metric value in its own unit, for the summary table and the dot strips. */
export function metricValue(value: number | null | undefined, unit: string | null): string {
  if (value == null) return 'NULL'
  if (unit === 'byte') return bytes(value)
  if (unit === 'core' || unit === 'cpu') return value.toFixed(2)
  return num(Math.round(value * 100) / 100)
}
