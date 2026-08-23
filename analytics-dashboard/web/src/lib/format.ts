/** Number and label formatting shared by the pages. Every function accepts null
    and returns '' for it, so a missing mart value renders as a blank cell, not
    as "NaN" or "null". */

export function fmt(n: number | null | undefined, digits = 0): string {
  if (n === null || n === undefined || Number.isNaN(n)) return ''
  return n.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })
}

export function signed(n: number | null | undefined, digits = 1): string {
  if (n === null || n === undefined || Number.isNaN(n)) return ''
  return (n > 0 ? '+' : '') + fmt(n, digits)
}

export function pct(x: number | null | undefined, digits = 0): string {
  if (x === null || x === undefined) return ''
  return fmt(x * 100, digits) + '%'
}

/** A spread as the market writes it: -3.5, +7, PK at zero. */
export function spreadText(s: number | null | undefined): string {
  if (s === null || s === undefined) return ''
  if (s === 0) return 'PK'
  return (s > 0 ? '+' : '') + fmt(s, 1)
}

/** American odds: +150, -114. */
export function odds(n: number | null | undefined): string {
  if (n === null || n === undefined) return ''
  return (n > 0 ? '+' : '') + fmt(n, 0)
}

export type Tone = 'pos' | 'neg' | 'flat' | ''

export function tone(n: number | null | undefined): Tone {
  if (n === null || n === undefined) return ''
  return n > 0 ? 'pos' : n < 0 ? 'neg' : 'flat'
}

export function ordinal(n: number): string {
  const s = ['th', 'st', 'nd', 'rd']
  const v = n % 100
  return n + (s[(v - 20) % 10] ?? s[v] ?? s[0] ?? 'th')
}

/** "Sun 1:00 PM" from the mart's kickoff slot; the slot already carries the day. */
export function slotLabel(slot: string): string {
  return slot.toUpperCase()
}

export function titleCase(s: string | null | undefined): string {
  if (!s) return ''
  return s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())
}
