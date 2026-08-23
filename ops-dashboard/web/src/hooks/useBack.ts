import { useCallback } from 'react'
import { useNavigate } from 'react-router-dom'

/** Go back the way the user came when they navigated inside the app; go to
    `fallback` when this page was the entry point (a shared link, a reload into
    a fresh tab). react-router keeps its own index in history.state, 0 on the
    first entry. */
export function useBack(fallback: { pathname: string; search?: string } | string): () => void {
  const navigate = useNavigate()
  return useCallback(() => {
    const idx = (window.history.state as { idx?: number } | null)?.idx ?? 0
    if (idx > 0) navigate(-1)
    else navigate(fallback, { replace: true })
  }, [navigate, fallback])
}
