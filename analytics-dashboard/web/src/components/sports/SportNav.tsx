import { NavLink } from 'react-router-dom'
import type { Capability, CapabilitiesPayload } from '../../api/sports/types.ts'
import type { Viewport } from '../../hooks/useViewport.ts'

interface Item {
  to: string
  label: string
  cap: Capability | null
}

// One list, rendered as the floating dock on wide screens and as bottom tabs on
// narrow ones. Items appear only when the sport has the capability; the
// Explorer always does.
const ITEMS: Item[] = [
  { to: 'slate', label: 'Game day', cap: 'schedule' },
  { to: 'teams', label: 'Teams', cap: 'team_performance' },
  { to: 'players', label: 'Players', cap: 'player_performance' },
  { to: 'markets', label: 'Markets', cap: 'game_odds' },
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
  const items = ITEMS.filter((it) => it.cap === null || caps?.capabilities.includes(it.cap))
  return (
    <nav className={viewport === 'narrow' ? 'tabs' : 'dock'} aria-label="Pages">
      <NavLink to={`/${sport}`} end>
        <span>Home</span>
      </NavLink>
      {items.map((it) => (
        <NavLink key={it.to} to={`/${sport}/${it.to}`}>
          <span>{it.label}</span>
        </NavLink>
      ))}
    </nav>
  )
}
