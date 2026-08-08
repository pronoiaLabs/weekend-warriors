import { useSearchParams } from 'react-router-dom'

export const ALL_SPORTS = 'all'

/** The sport filter lives in the URL so it survives a reload and can be shared,
    and so every page reads one predicate rather than holding its own copy. */
export function useSportFilter() {
  const [params, setParams] = useSearchParams()
  const sport = params.get('sport') ?? ALL_SPORTS

  function setSport(next: string) {
    const updated = new URLSearchParams(params)
    if (next === ALL_SPORTS) {
      updated.delete('sport')
    } else {
      updated.set('sport', next)
    }
    setParams(updated, { replace: true })
  }

  return { sport, setSport, search: sport === ALL_SPORTS ? '' : `?sport=${sport}` }
}
