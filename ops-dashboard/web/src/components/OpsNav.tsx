import { NavLink, useLocation } from 'react-router-dom'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import type { Viewport } from '../hooks/useViewport.ts'

interface Item {
  to: string
  label: string
  /** first path segments this item owns: a run or pipeline page belongs to Pipelines */
  also: string[]
}

// One list, rendered as the floating dock on wide screens and as bottom tabs
// on narrow ones. Every link carries the sport and date filters.
const ITEMS: Item[] = [
  { to: '/', label: 'Dashboard', also: [] },
  { to: '/pipelines', label: 'Pipelines', also: ['ingestion', 'runs'] },
  { to: '/builds', label: 'Builds', also: ['dbt'] },
]

export default function OpsNav({ viewport }: { viewport: Viewport }) {
  const search = useOpsSearch()
  const { pathname } = useLocation()
  const segment = pathname.split('/')[1] ?? ''
  return (
    <nav className={viewport === 'narrow' ? 'tabs' : 'dock'} aria-label="Pages">
      {ITEMS.map((it) => {
        const owns = it.also.includes(segment)
        return (
          <NavLink key={it.to} to={{ pathname: it.to, search }} end={it.to === '/'} className={({ isActive }) => (isActive || owns ? 'active' : '')}>
            <span>{it.label}</span>
          </NavLink>
        )
      })}
    </nav>
  )
}
