import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import type { Capability } from '../../api/sports/types.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'

const LABELS: Record<Capability, string> = {
  schedule: 'game day',
  game_prop_board: 'game prop board',
  team_standings: 'standings',
  team_weeks: 'team week',
  team_allowed: 'defense allowed',
  team_ats: 'against the spread',
  player_leaders: 'player leaderboard',
  player_weeks: 'player week',
  player_week_stats: 'player stat',
  player_defense_weeks: 'defender week',
  game_odds: 'market',
  player_props: 'props',
  news: 'news',
}

/** Renders its page only when the sport has the capability. The nav already
    hides the link; this covers a typed or shared URL, and says which mart is
    missing instead of letting the API's 404 surface as a broken page. */
export default function CapabilityGate({ cap, children }: { cap: Capability; children: ReactNode }) {
  const sport = useSportParam()
  const caps = useCapabilities()
  if (caps === null) {
    return (
      <div className="page">
        <section className="tile">
          <p className="hint">Loading {sport.toUpperCase()}...</p>
        </section>
      </div>
    )
  }
  if (!caps.capabilities.includes(cap)) {
    return (
      <div className="page">
        <div className="page-head">
          <h1>No {LABELS[cap]} data yet</h1>
          <p className="lede">
            {caps.label} has no <code>{cap}</code> mart in {caps.app_location}. It arrives with that
            sport's APP layer. Back to <Link to={`/${sport}`}>home</Link>.
          </p>
        </div>
      </div>
    )
  }
  return <>{children}</>
}
