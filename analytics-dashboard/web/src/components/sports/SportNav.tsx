import { NavLink, useLocation } from 'react-router-dom'
import type { Capability, CapabilitiesPayload } from '../../api/sports/types.ts'
import type { Viewport } from '../../hooks/useViewport.ts'
import { boardPath, useView } from '../../state/view.tsx'

interface Item {
  to: string
  label: string
  cap: Capability | null
  /** other first path segments this item owns (a game page belongs to Game day) */
  also?: string[]
}

// One list, rendered as the floating dock on wide screens and as bottom tabs on
// narrow ones. Items appear only when the sport has the capability; the
// Explorer always does.
const ITEMS: Item[] = [
  { to: 'slate', label: 'Game day', cap: 'schedule', also: ['games'] },
  { to: 'teams', label: 'Teams', cap: 'team_standings' },
  { to: 'players', label: 'Players', cap: 'player_leaders' },
  { to: 'markets', label: 'Markets', cap: 'line_history' },
  { to: 'news', label: 'News', cap: 'news' },
  { to: 'explore', label: 'Explorer', cap: null },
]

export default function SportNav({
  sport,
  caps,
  viewport,
}: {
  sport: string
  caps: CapabilitiesPayload | null
  viewport: Viewport
}) {
  const { view } = useView()
  const { pathname } = useLocation()
  const segment = pathname.split('/')[2] ?? ''
  const items = ITEMS.filter((it) => it.cap === null || caps?.capabilities.includes(it.cap))
  return (
    <nav className={viewport === 'narrow' ? 'tabs' : 'dock'} aria-label="Pages">
      <NavLink to={`/${sport}`} end>
        <span>Home</span>
      </NavLink>
      {items.map((it) => {
        // Game day returns to the remembered week and book, not the defaults
        const to = it.to === 'slate' ? boardPath(sport, view) : `/${sport}/${it.to}`
        const owns = it.also?.includes(segment) ?? false
        return (
          <NavLink key={it.to} to={to} className={({ isActive }) => (isActive || owns ? 'active' : '')}>
            <span>{it.label}</span>
          </NavLink>
        )
      })}
    </nav>
  )
}
