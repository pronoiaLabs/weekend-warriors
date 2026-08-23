import { Link, Outlet } from 'react-router-dom'
import { fetchSports } from '../api/client.ts'
import Aurora from '../components/Aurora.tsx'
import OpsNav from '../components/OpsNav.tsx'
import { useApi } from '../hooks/useApi.ts'
import { useOpsSearch } from '../hooks/useDayParam.ts'
import { useWindowScrollMemory } from '../hooks/useScrollMemory.ts'
import { ALL_SPORTS, useSportFilter } from '../hooks/useSportFilter.ts'
import { useTheme } from '../hooks/useTheme.ts'
import { useTilt } from '../hooks/useTilt.ts'
import { useViewport } from '../hooks/useViewport.ts'
import { ChromeProvider, useChrome } from '../state/chrome.tsx'
import { hhmm } from '../utils/format.ts'

/** The one shell every page renders inside: the topbar with the sport filter
    made visible, the page, the dock (bottom tabs under 900px) and the footer.
    The ?sport= filter deliberately survives navigation so views stay
    deep-linkable, and an invisible sticky filter is a trap: the switch in the
    topbar is its face on every page, always showing what is active. */
export default function OpsLayout() {
  return (
    <ChromeProvider>
      <Shell />
    </ChromeProvider>
  )
}

function Shell() {
  const viewport = useViewport()
  const search = useOpsSearch()
  const { sport, setSport } = useSportFilter()
  const { now } = useChrome()
  const { theme, toggle } = useTheme()
  const sports = useApi((signal) => fetchSports(signal), [])
  useTilt()
  useWindowScrollMemory()

  const list = [ALL_SPORTS, ...(sports.data?.sports.map((s) => s.sport) ?? [])]

  return (
    <>
      <Aurora />
      <div className={`shell shell-${viewport}`}>
        <header className="topbar">
          <Link to={{ pathname: '/', search }} className="brand">
            <span className="mark" aria-hidden="true" />
            <span className="word">Weekend Warriors</span>
            <span className="sub">ops</span>
          </Link>
          <nav className="sport-switch" aria-label="Sport filter">
            {list.map((value) => (
              <button key={value} type="button" className={value === sport ? 'on' : ''} onClick={() => setSport(value)}>
                {value === ALL_SPORTS ? 'ALL' : value}
              </button>
            ))}
          </nav>
          <div className="context">
            {now && (
              <span className="ctx-item">
                <span className="l">Refreshed</span>
                <span className="v">
                  <i className="live" aria-hidden="true" />
                  {hhmm(now)}
                </span>
              </span>
            )}
            <span className="ctx-item">
              <span className="l">Updates</span>
              <span className="v">event-driven</span>
            </span>
          </div>
          <button type="button" className="theme-toggle" onClick={toggle} aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}>
            <i className="sw" aria-hidden="true" />
            {theme === 'dark' ? 'Light' : 'Dark'}
          </button>
        </header>

        <main className="main">
          <Outlet />
        </main>

        <OpsNav viewport={viewport} />

        <footer className="foot">
          <span>Reads the DLT_DB.OPS copy in app.observability: pipeline runs, logs, metrics and dbt builds.</span>
          <span>{sports.data ? `${sports.data.sports.length} sports registered` : ''}</span>
        </footer>
      </div>
    </>
  )
}
