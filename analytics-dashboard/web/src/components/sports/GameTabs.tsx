import { NavLink } from 'react-router-dom'
import Crumbs from './Crumbs.tsx'

/** The game family's shared chrome: breadcrumb back to the slate, the back
    button, and the four-room sub-nav (Overview / Prop board / Situations /
    Lines). Each tab page renders this with what it knows; there is no shared
    layout fetch, so a deep link into any tab stands on its own. */
export default function GameTabs({
  sport,
  gameKey,
  matchup,
  tab,
  boardHref,
  back,
  vendorParam,
}: {
  sport: string
  gameKey: string
  matchup: string
  tab: 'Overview' | 'Prop board' | 'Situations' | 'Lines'
  boardHref: string
  back: () => void
  vendorParam?: string
}) {
  const base = `/${sport}/games/${encodeURIComponent(gameKey)}`
  const q = vendorParam ? `?vendor=${encodeURIComponent(vendorParam)}` : ''
  const tabs: { label: string; to: string; end?: boolean }[] = [
    { label: 'Overview', to: `${base}${q}`, end: true },
    { label: 'Prop board', to: `${base}/props${q}` },
    { label: 'Situations', to: `${base}/situations` },
    { label: 'Lines', to: `${base}/lines${q}` },
  ]
  return (
    <>
      <div className="crumb-row">
        <Crumbs items={[{ label: 'Game day', to: boardHref }, { label: matchup }, { label: tab }]} />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to the slate
        </button>
      </div>
      <nav className="subnav" aria-label="Game pages">
        {tabs.map((t) => (
          <NavLink key={t.label} to={t.to} end={t.end} className={({ isActive }) => (isActive ? 'on' : '')}>
            {t.label}
          </NavLink>
        ))}
      </nav>
    </>
  )
}
