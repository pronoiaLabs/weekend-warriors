import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react'

/** What a page tells the shell: the payload's clock. The topbar shows it as
    the freshness pill, and it is always the API's clock, never the browser's,
    so a stale tab does not age itself. Pages set it when their payload lands
    and clear it on the way out. */
interface ChromeValue {
  now: string | null
  setNow: (now: string | null) => void
}

const ChromeContext = createContext<ChromeValue | null>(null)

export function ChromeProvider({ children }: { children: ReactNode }) {
  const [now, setNowState] = useState<string | null>(null)
  const setNow = useCallback((value: string | null) => setNowState(value), [])
  const value = useMemo(() => ({ now, setNow }), [now, setNow])
  return <ChromeContext.Provider value={value}>{children}</ChromeContext.Provider>
}

export function useChrome(): ChromeValue {
  const ctx = useContext(ChromeContext)
  if (!ctx) throw new Error('useChrome outside ChromeProvider')
  return ctx
}
