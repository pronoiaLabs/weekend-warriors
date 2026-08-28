import { useEffect, useState } from 'react'
import { fetchBranding } from '../api/sports/client.ts'
import type { BrandingRow } from '../api/sports/types.ts'

/** Team branding, fetched once per sport for the whole session and joined by
    team_key (every mart carries it). A failed fetch resolves to an empty map:
    pages render text labels and neutral accents instead of logos. */

const cache = new Map<string, Promise<Map<string, BrandingRow>>>()

function load(sport: string): Promise<Map<string, BrandingRow>> {
  let promise = cache.get(sport)
  if (!promise) {
    promise = fetchBranding(sport)
      .then((payload) => new Map(payload.rows.map((r) => [r.team_key, r])))
      .catch(() => {
        cache.delete(sport) // retry on the next mount rather than caching the failure
        return new Map<string, BrandingRow>()
      })
    cache.set(sport, promise)
  }
  return promise
}

export function useBranding(sport: string): Map<string, BrandingRow> {
  const [byTeamKey, setByTeamKey] = useState<Map<string, BrandingRow>>(new Map())
  useEffect(() => {
    let alive = true
    load(sport).then((map) => {
      if (alive) setByTeamKey(map)
    })
    return () => {
      alive = false
    }
  }, [sport])
  return byTeamKey
}

/** color_primary as an accent only, behind a floor so a near-black brand color
    stays visible on the dark ground (and a near-white one on light). */
export function teamAccent(row: BrandingRow | undefined): string | undefined {
  const hex = row?.color_primary
  if (!hex || !/^#?[0-9a-f]{6}$/i.test(hex)) return undefined
  const h = hex.replace('#', '')
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16))
  const luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
  if (luma < 24 || luma > 232) return row?.color_secondary ?? undefined
  return `#${h}`
}
