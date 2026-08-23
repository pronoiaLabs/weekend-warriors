import { useSearchParams } from 'react-router-dom'
import { isSlateKind, isSlateView, type SlateKind, type SlateView } from '../utils/slateView.ts'

/** The slate's view and kind chips live in the URL next to sport and date, so a
    filtered board is shareable and survives a reload. Defaults stay out of the
    query string the same way today and ALL do. */
export function useSlateFilters() {
  const [params, setParams] = useSearchParams()
  const rawView = params.get('view')
  const rawKind = params.get('kind')
  const view: SlateView = isSlateView(rawView) ? rawView : 'all'
  const kind: SlateKind = isSlateKind(rawKind) ? rawKind : 'all'

  function patch(next: { view?: SlateView; kind?: SlateKind }) {
    const updated = new URLSearchParams(params)
    const nextView = next.view ?? view
    const nextKind = next.kind ?? kind
    if (nextView === 'all') updated.delete('view')
    else updated.set('view', nextView)
    if (nextKind === 'all') updated.delete('kind')
    else updated.set('kind', nextKind)
    setParams(updated, { replace: true })
  }

  return {
    view,
    kind,
    setView: (next: SlateView) => patch({ view: next }),
    setKind: (next: SlateKind) => patch({ kind: next }),
  }
}
