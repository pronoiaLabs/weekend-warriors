import { Link } from 'react-router-dom'
import { fetchHealth } from '../../api/sports/client.ts'
import { useApi } from '../../hooks/useApi.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'

const LABELS: Record<string, string> = {
  schedule: 'Game day board',
  game_prop_board: 'Game prop board',
  team_standings: 'Standings',
  team_weeks: 'Team weeks',
  team_allowed: 'Defense allowed by position',
  team_ats: 'Against the spread',
  player_leaders: 'Player leaderboards',
  player_weeks: 'Player weeks',
  player_week_stats: 'Player stats, week by week',
  player_defense_weeks: 'Defender weeks',
  line_history: 'Markets',
  prop_line_history: 'Prop line history',
  news: 'News',
  explore_player_games: 'Explorer: player games',
  explore_defender_games: 'Explorer: defender games',
  explore_team_games: 'Explorer: team games',
  explore_game_lines: 'Explorer: game lines',
  explore_player_props: 'Explorer: player props',
  explore_news: 'Explorer: news',
  explore_line_moves: 'Explorer: line moves',
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
                {c === 'schedule' ? (
                  <Link to={`/${sport}/slate`}>{LABELS[c]}</Link>
                ) : c === 'team_standings' ? (
                  <Link to={`/${sport}/teams`}>{LABELS[c]}</Link>
                ) : c === 'player_leaders' ? (
                  <Link to={`/${sport}/players`}>{LABELS[c]}</Link>
                ) : c === 'line_history' ? (
                  <Link to={`/${sport}/markets`}>{LABELS[c]}</Link>
                ) : c === 'news' ? (
                  <Link to={`/${sport}/news`}>{LABELS[c]}</Link>
                ) : c.startsWith('explore_') ? (
                  <Link to={`/${sport}/explore?sheet=${c.slice('explore_'.length)}`}>{LABELS[c]}</Link>
                ) : (
                  <b>{LABELS[c] ?? c}</b>
                )}
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
