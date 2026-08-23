import { createContext, useContext } from 'react'
import { Link, Outlet } from 'react-router-dom'
import { fetchCapabilities } from '../api/sports/client.ts'
import type { CapabilitiesPayload } from '../api/sports/types.ts'
import Aurora from '../components/Aurora.tsx'
import SportNav from '../components/sports/SportNav.tsx'
import { useApi } from '../hooks/useApi.ts'
import { useSportParam } from '../hooks/useSportParam.ts'
import { useTilt } from '../hooks/useTilt.ts'
import { useViewport } from '../hooks/useViewport.ts'

const CapabilitiesContext = createContext<CapabilitiesPayload | null>(null)

/** The sport's capabilities, loaded once per sport by the layout. Pages and
    gates read this instead of fetching again. */
export function useCapabilities(): CapabilitiesPayload | null {
  return useContext(CapabilitiesContext)
}

const SPORTS = ['nfl', 'ncaaf']

export default function SportLayout() {
  const sport = useSportParam()
  const viewport = useViewport()
  const caps = useApi((signal) => fetchCapabilities(sport, signal), [sport])
  useTilt()

  return (
    <CapabilitiesContext.Provider value={caps.data}>
      <Aurora />
      <div className={`shell shell-${viewport}`}>
        <header className="topbar">
          <Link to={`/${sport}`} className="brand">
            <span className="mark" aria-hidden="true" />
            <span className="word">Weekend Warriors</span>
            <span className="sub">analytics</span>
          </Link>
          <nav className="sport-switch" aria-label="Sport">
            {SPORTS.map((s) => (
              <Link key={s} to={`/${s}`} className={s === sport ? 'on' : ''}>
                {s.toUpperCase()}
              </Link>
            ))}
          </nav>
          {caps.data && (
            <div className="context">
              <span className="ctx-item">
                <span className="l">Season</span>
                <span className="v">{caps.data.default_season}</span>
              </span>
              <span className="ctx-item">
                <span className="l">Data</span>
                <span className="v">{caps.data.data}</span>
              </span>
            </div>
          )}
        </header>

        <main className="main">
          {caps.error ? (
            <section className="tile">
              <header className="tile-head">
                <h2>No such sport</h2>
              </header>
              <p className="lede">
                {caps.error}. Try <Link to="/nfl">NFL</Link>.
              </p>
            </section>
          ) : (
            <Outlet />
          )}
        </main>

        <SportNav sport={sport} caps={caps.data} viewport={viewport} />

        <footer className="foot">
          <span>Pages read the dbt APP layer; the Explorer reads the semantic views.</span>
          {caps.data && <span>{caps.data.app_location}</span>}
        </footer>
      </div>
    </CapabilitiesContext.Provider>
  )
}
