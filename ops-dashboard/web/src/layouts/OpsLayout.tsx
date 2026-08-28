import { useState } from 'react'
import { Link, Outlet } from 'react-router-dom'
import { fetchSports, triggerRefresh } from '../api/client.ts'
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

  // The scheduled path is hourly; this is the "I need it now" valve. The copy
  // container takes minutes, so "copy started" is the honest success state --
  // the Refreshed clock shows when data actually lands.
  const [refreshing, setRefreshing] = useState(false)
  const [refreshNote, setRefreshNote] = useState<string | null>(null)
  async function onRefresh() {
    if (refreshing) return
    setRefreshing(true)
    setRefreshNote(null)
    try {
      const result = await triggerRefresh()
      const failed = Object.values(result).find((m) => m.startsWith('error:'))
      if (failed) setRefreshNote(failed)
      else setRefreshNote(result.obs_copy === 'fired' ? 'copy started' : result.obs_copy)
    } catch (err) {
      setRefreshNote(err instanceof Error ? err.message : 'refresh failed')
    } finally {
      setRefreshing(false)
    }
  }

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
            <button
              type="button"
              className="ctx-item refresh-now"
              onClick={onRefresh}
              disabled={refreshing}
              title={refreshNote ?? 'Run the observability refresh and Postgres copy now'}
            >
              <span className="l">Updates hourly</span>
              <span className="v">{refreshing ? 'refreshing…' : (refreshNote ?? 'refresh now')}</span>
            </button>
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
