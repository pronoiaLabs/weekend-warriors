import { useEffect, useLayoutEffect } from 'react'
import { useLocation, useNavigationType } from 'react-router-dom'

const PREFIX = 'ww.ops.scroll.'

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
    Forward return to where the user was. Keyed by the history entry, so two
    visits to the same URL are remembered separately. */
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
      const raf = requestAnimationFrame(() => window.scrollTo(at?.x ?? 0, at?.y ?? 0))
      return () => cancelAnimationFrame(raf)
    }
    window.scrollTo(0, 0)
    return undefined
  }, [location.key, type])
}
