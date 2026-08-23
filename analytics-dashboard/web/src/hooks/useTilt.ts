import { useEffect } from 'react'

/** Pointer tilt for every [data-tilt] element: one document listener, the
    transform set on the hovered element only, capped by the --tilt-deg token.
    Off entirely under prefers-reduced-motion and on devices without hover, the
    same two conditions sports.css uses to drop the transition. */
export function useTilt(): void {
  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    if (!window.matchMedia('(hover: hover)').matches) return
    const deg = Number(getComputedStyle(document.documentElement).getPropertyValue('--tilt-deg')) || 6
    let raf: number | null = null
    let active: HTMLElement | null = null

    const reset = () => {
      if (active) {
        active.classList.remove('tilting')
        active.style.transform = ''
        active = null
      }
    }
    const onMove = (e: PointerEvent) => {
      const el = (e.target as Element | null)?.closest<HTMLElement>('[data-tilt]') ?? null
      if (el !== active) reset()
      if (!el) return
      active = el
      if (raf !== null) cancelAnimationFrame(raf)
      raf = requestAnimationFrame(() => {
        const r = el.getBoundingClientRect()
        const px = (e.clientX - r.left) / r.width - 0.5
        const py = (e.clientY - r.top) / r.height - 0.5
        el.classList.add('tilting')
        el.style.transform = `perspective(900px) rotateX(${(-py * deg).toFixed(2)}deg) rotateY(${(px * deg).toFixed(2)}deg) translateZ(6px)`
      })
    }
    document.addEventListener('pointermove', onMove, { passive: true })
    document.addEventListener('pointerleave', reset, true)
    return () => {
      document.removeEventListener('pointermove', onMove)
      document.removeEventListener('pointerleave', reset, true)
      if (raf !== null) cancelAnimationFrame(raf)
      reset()
    }
  }, [])
}
