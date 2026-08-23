import { useEffect, useLayoutEffect, type RefObject } from 'react'
import { useLocation, useNavigationType } from 'react-router-dom'

const PREFIX = 'ww.analytics.scroll.'

function load(key: string): { x: number; y: number } | null {
  try {
    const raw = sessionStorage.getItem(PREFIX + key)
    return raw ? (JSON.parse(raw) as { x: number; y: number }) : null
  } catch {
    return null
  }
}

function save(key: string, x: number, y: number): void {
  try {
    sessionStorage.setItem(PREFIX + key, JSON.stringify({ x, y }))
  } catch {
    // blocked storage: no restore, nothing else changes
  }
}

/** Window scroll across navigations: a new page starts at the top, Back and
    Forward return to where the user was. BrowserRouter does not do this; the
    browser's own restoration only covers full loads. Keyed by the history
    entry, so two visits to the same URL are remembered separately. */
export function useWindowScrollMemory(): void {
  const location = useLocation()
  const type = useNavigationType()

  useEffect(() => {
    const key = location.key
    const onScroll = () => save(key, window.scrollX, window.scrollY)
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [location.key])

  useLayoutEffect(() => {
    if (type === 'POP') {
      const at = load(location.key)
      // the page's data arrives a tick later; restore after it has had a frame
      const raf = requestAnimationFrame(() => window.scrollTo(at?.x ?? 0, at?.y ?? 0))
      return () => cancelAnimationFrame(raf)
    }
    window.scrollTo(0, 0)
    return undefined
  }, [location.key, type])
}

/** The same for an element that scrolls on its own (the board), keyed by the
    page URL so returning to the same week finds the same slot. `ready` gates
    the restore until the rows are rendered, otherwise there is nothing to
    scroll yet. */
export function useElementScrollMemory(ref: RefObject<HTMLElement | null>, key: string, ready: boolean): void {
  useEffect(() => {
    const el = ref.current
    if (!ready || !el) return
    const at = load(key)
    if (at) {
      el.scrollTop = at.y
      el.scrollLeft = at.x
    }
    const onScroll = () => save(key, el.scrollLeft, el.scrollTop)
    el.addEventListener('scroll', onScroll, { passive: true })
    return () => el.removeEventListener('scroll', onScroll)
  }, [ref, key, ready])
}
