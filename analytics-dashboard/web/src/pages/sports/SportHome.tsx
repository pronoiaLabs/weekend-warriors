import { Link } from 'react-router-dom'
import { fetchHealth } from '../../api/sports/client.ts'
import { useApi } from '../../hooks/useApi.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'

const LABELS: Record<string, string> = {
  schedule: 'Game day board',
  game_prop_board: 'Game prop board',
  team_performance: 'Teams',
  player_performance: 'Players',
  game_odds: 'Markets',
  player_props: 'Props edge',
  news: 'News',
}

export default function SportHome() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const health = useApi((signal) => fetchHealth(signal), [])

  return (
    <div className="page">
      <div className="page-head">
        <h1>{caps?.label ?? sport.toUpperCase()}</h1>
        <p className="lede">
          Pages are served from the dbt APP layer at {caps?.app_location ?? '...'}. The nav shows only
          what this sport has data for.
        </p>
      </div>

      <div className="kpis">
        <div className="kpi" data-tilt>
          <span className="l">API</span>
          <span className="v">{health.loading ? '...' : health.error ? 'down' : health.data?.ok ? 'up' : 'down'}</span>
          <span className="s">{health.data ? `${health.data.data} mode as ${health.data.role}` : health.error ?? ''}</span>
        </div>
        <div className="kpi">
          <span className="l">Capabilities</span>
          <span className="v">{caps ? caps.capabilities.length : '...'}</span>
          <span className="s">{caps?.extensions.length ? `extensions: ${caps.extensions.join(', ')}` : 'no extensions'}</span>
        </div>
        <div className="kpi">
          <span className="l">Season</span>
          <span className="v">{caps?.default_season ?? '...'}</span>
          <span className="s">{caps?.default_vendor ? `default book ${caps.default_vendor}` : 'no odds feed'}</span>
        </div>
      </div>

      <section className="tile">
        <header className="tile-head">
          <h2>What this sport can show</h2>
          <span className="meta">from /api/{sport}/capabilities</span>
        </header>
        {caps && caps.capabilities.length > 0 ? (
          <ul className="links">
            {caps.capabilities.map((c) => (
              <li key={c}>
                {c === 'schedule' ? <Link to={`/${sport}/slate`}>{LABELS[c]}</Link> : <b>{LABELS[c] ?? c}</b>}
                <small>{c}</small>
              </li>
            ))}
          </ul>
        ) : (
          <p className="hint">No page marts yet for this sport. The Explorer still works once it lands.</p>
        )}
      </section>
    </div>
  )
}
