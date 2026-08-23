import { useSearchParams } from 'react-router-dom'

/** The day under inspection lives in the URL beside the sport filter, so a slate
    is shareable and survives a reload. Null means today, which is what the API
    assumes when `date` is omitted: the dashboard never writes today's date into
    the URL, because a pinned date would go stale in an open tab. */
export function useDayParam() {
  const [params, setParams] = useSearchParams()
  const day = params.get('date')

  function setDay(next: string | null) {
    // A copy, never the live params: mutating in place would drop ?sport=.
    const updated = new URLSearchParams(params)
    if (next === null) {
      updated.delete('date')
    } else {
      updated.set('date', next)
    }
    setParams(updated, { replace: true })
  }

  return { day, setDay }
}

/** The query string every in-app link should carry: sport, date and the slate
    chips together, in a fixed order so links do not churn. Pages that only care
    about the sport can keep using useSportFilter().search. */
export function useOpsSearch(): string {
  const [params] = useSearchParams()
  const preserved = new URLSearchParams()
  for (const key of ['sport', 'date', 'view', 'kind'] as const) {
    const value = params.get(key)
    if (value) preserved.set(key, value)
  }
  const query = preserved.toString()
  return query ? `?${query}` : ''
}
