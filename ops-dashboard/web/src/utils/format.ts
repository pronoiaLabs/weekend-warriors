/** Everything on this dashboard is UTC: the Tasks are scheduled in UTC and the
    views record UTC, so no formatter here reads the browser time zone. */

const HHMM = new Intl.DateTimeFormat('en-GB', {
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
  timeZone: 'UTC',
})

const WEEKDAY = new Intl.DateTimeFormat('en-US', { weekday: 'short', timeZone: 'UTC' })
const WEEKDAY_LONG = new Intl.DateTimeFormat('en-US', { weekday: 'long', timeZone: 'UTC' })
const MONTH_DAY = new Intl.DateTimeFormat('en-US', {
  month: 'short',
  day: 'numeric',
  timeZone: 'UTC',
})
const MONTH_DAY_YEAR = new Intl.DateTimeFormat('en-US', {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
  timeZone: 'UTC',
})

export function hhmm(iso: string): string {
  return HHMM.format(new Date(iso))
}

export function weekday(iso: string): string {
  return WEEKDAY.format(new Date(iso))
}

/** "Tue 08-11 13:00", the shape the wireframe uses for a next fire. */
export function dayHhmm(iso: string): string {
  const at = new Date(iso)
  return `${WEEKDAY.format(at)} ${at.toISOString().slice(5, 10)} ${HHMM.format(at)}`
}

/** "AUG 7", used inside anomaly badges. */
export function shortDate(iso: string): string {
  return MONTH_DAY.format(new Date(iso)).toUpperCase()
}

/** "Saturday 2026-08-08" from a bare YYYY-MM-DD. */
export function longDay(isoDate: string): string {
  return `${WEEKDAY_LONG.format(new Date(`${isoDate}T00:00:00Z`))} ${isoDate}`
}

/** "Saturday, Aug 8 2026" from a bare YYYY-MM-DD, the incident feed day header. */
export function longDayTitle(isoDate: string): string {
  const at = new Date(`${isoDate}T00:00:00Z`)
  return `${WEEKDAY_LONG.format(at)}, ${MONTH_DAY_YEAR.format(at).replace(',', '')}`
}

export function num(value: number | null | undefined): string {
  return value == null ? '0' : value.toLocaleString('en-US')
}

export function duration(seconds: number | null | undefined): string | null {
  return seconds == null ? null : `${seconds} s`
}
