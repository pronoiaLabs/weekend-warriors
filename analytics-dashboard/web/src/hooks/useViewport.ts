import { useEffect, useState } from 'react'

export type Viewport = 'wide' | 'narrow'

const QUERY = '(max-width: 900px)'

/** One URL, two chrome. The breakpoint is the one sports.css uses for the
    dock-versus-bottom-tabs switch; matchMedia keeps the two in step. Never the
    user agent. */
export function useViewport(): Viewport {
  const [narrow, setNarrow] = useState(() => window.matchMedia(QUERY).matches)
  useEffect(() => {
    const mq = window.matchMedia(QUERY)
    const onChange = (e: MediaQueryListEvent) => setNarrow(e.matches)
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [])
  return narrow ? 'narrow' : 'wide'
}
