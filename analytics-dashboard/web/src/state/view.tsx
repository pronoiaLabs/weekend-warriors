import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'

/** What the user last chose on a sport's pages: the slice of the schedule they
    are looking at and the book they read lines from. The URL is always the
    source of truth for the page that is open; this is the memory that lets the
    dock, the breadcrumb and "Back to board" return to the same slice instead of
    the defaults. Kept in sessionStorage per sport, so a reload keeps it and a
    new tab starts clean. */
export interface ViewState {
  season?: number
  season_type?: string
  week?: number
  vendor?: string
  outdoor?: boolean
}

export const VIEW_KEYS = ['season', 'season_type', 'week', 'vendor', 'outdoor'] as const

interface ViewContextValue {
  view: ViewState
  /** merge a choice in (a page that owns one key, like the game page's book) */
  setView: (patch: Partial<ViewState>) => void
  /** replace the memory with exactly this (the board, which owns every key) */
  replaceView: (next: ViewState) => void
}

const ViewContext = createContext<ViewContextValue | null>(null)

const storageKey = (sport: string) => `ww.analytics.view.${sport}`

function read(sport: string): ViewState {
  try {
    const raw = sessionStorage.getItem(storageKey(sport))
    return raw ? clean(JSON.parse(raw) as ViewState) : {}
  } catch {
    return {}
  }
}

function write(sport: string, view: ViewState): void {
  try {
    sessionStorage.setItem(storageKey(sport), JSON.stringify(view))
  } catch {
    // blocked storage: the view lives for this render tree only
  }
}

/** Drop undefined, empty and false values so "no choice" never becomes a param. */
function clean(view: ViewState): ViewState {
  const out: ViewState = {}
  if (view.season !== undefined && !Number.isNaN(view.season)) out.season = view.season
  if (view.season_type) out.season_type = view.season_type
  if (view.week !== undefined && !Number.isNaN(view.week)) out.week = view.week
  if (view.vendor) out.vendor = view.vendor
  if (view.outdoor) out.outdoor = true
  return out
}

export function ViewProvider({ sport, children }: { sport: string; children: ReactNode }) {
  const [view, setViewState] = useState<ViewState>(() => read(sport))

  useEffect(() => {
    setViewState(read(sport))
  }, [sport])

  const setView = useCallback(
    (patch: Partial<ViewState>) => {
      setViewState((current) => {
        const next = clean({ ...current, ...patch })
        write(sport, next)
        return next
      })
    },
    [sport],
  )

  const replaceView = useCallback(
    (next: ViewState) => {
      const cleaned = clean(next)
      write(sport, cleaned)
      setViewState(cleaned)
    },
    [sport],
  )

  const value = useMemo(() => ({ view, setView, replaceView }), [view, setView, replaceView])
  return <ViewContext.Provider value={value}>{children}</ViewContext.Provider>
}

export function useView(): ViewContextValue {
  const ctx = useContext(ViewContext)
  if (!ctx) throw new Error('useView outside ViewProvider')
  return ctx
}

/** The view as URL search params (the slate's contract). */
export function viewToParams(view: ViewState): URLSearchParams {
  const params = new URLSearchParams()
  if (view.season !== undefined) params.set('season', String(view.season))
  if (view.season_type) params.set('season_type', view.season_type)
  if (view.week !== undefined) params.set('week', String(view.week))
  if (view.vendor) params.set('vendor', view.vendor)
  if (view.outdoor) params.set('outdoor', '1')
  return params
}

/** "?season_type=...&week=..." or "" when nothing is remembered. */
export function viewSearch(view: ViewState): string {
  const qs = viewToParams(view).toString()
  return qs ? `?${qs}` : ''
}

/** The view encoded in a page's search params; only the keys present. */
export function viewFromParams(search: URLSearchParams): ViewState {
  return clean({
    season: search.has('season') ? Number(search.get('season')) : undefined,
    season_type: search.get('season_type') ?? undefined,
    week: search.has('week') ? Number(search.get('week')) : undefined,
    vendor: search.get('vendor') ?? undefined,
    outdoor: search.get('outdoor') === '1',
  })
}

export function hasViewParams(search: URLSearchParams): boolean {
  return VIEW_KEYS.some((k) => search.has(k))
}

/** The board URL for a sport: the remembered slice, or the bare board. */
export function boardPath(sport: string, view: ViewState): string {
  return `/${sport}/slate${viewSearch(view)}`
}
