import { useCallback, useEffect, useState } from 'react'

export interface ApiState<T> {
  data: T | null
  error: string | null
  loading: boolean
  reload: () => void
}

/** Fetch lifecycle in one place: abort on unmount or dependency change, error
    text from the API's detail, a reload handle. Pages compose this with a
    TileFrame and a table; the copy-pasted useEffect triple from ops-dashboard
    does not come along. */
export function useApi<T>(fetcher: (signal: AbortSignal) => Promise<T>, deps: unknown[]): ApiState<T> {
  const [data, setData] = useState<T | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [tick, setTick] = useState(0)
  const reload = useCallback(() => setTick((t) => t + 1), [])

  useEffect(() => {
    const control = new AbortController()
    setLoading(true)
    fetcher(control.signal)
      .then((result) => {
        setData(result)
        setError(null)
        setLoading(false)
      })
      .catch((err: unknown) => {
        if (control.signal.aborted) return
        setData(null)
        setError(err instanceof Error ? err.message : String(err))
        setLoading(false)
      })
    return () => control.abort()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick])

  return { data, error, loading, reload }
}
