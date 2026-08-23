import { useSearchParams } from 'react-router-dom'
import { ALL_SOURCES, isSlateKind, isSlateView, type SlateKind, type SlateView } from '../utils/slateView.ts'

/** The slate's view, kind and source chips live in the URL next to sport and
    date, so a filtered board is shareable and survives a reload. Defaults stay
    out of the query string the same way today and ALL do. The source value is
    the registry's raw `source` (rest_api, nflverse, sleeper ...), unvalidated
    here: a source that is not on the day simply matches nothing. */
export function useSlateFilters() {
  const [params, setParams] = useSearchParams()
  const rawView = params.get('view')
  const rawKind = params.get('kind')
  const view: SlateView = isSlateView(rawView) ? rawView : 'all'
  const kind: SlateKind = isSlateKind(rawKind) ? rawKind : 'all'
  const source: string = params.get('source') || ALL_SOURCES

  function patch(next: { view?: SlateView; kind?: SlateKind; source?: string }) {
    const updated = new URLSearchParams(params)
    const nextView = next.view ?? view
    const nextKind = next.kind ?? kind
    const nextSource = next.source ?? source
    if (nextView === 'all') updated.delete('view')
    else updated.set('view', nextView)
    if (nextKind === 'all') updated.delete('kind')
    else updated.set('kind', nextKind)
    if (nextSource === ALL_SOURCES) updated.delete('source')
    else updated.set('source', nextSource)
    setParams(updated, { replace: true })
  }

  return {
    view,
    kind,
    source,
    setView: (next: SlateView) => patch({ view: next }),
    setKind: (next: SlateKind) => patch({ kind: next }),
    setSource: (next: string) => patch({ source: next }),
  }
}
