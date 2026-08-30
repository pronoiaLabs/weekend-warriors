import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { PULSE_CAPS } from './components/sports/SportNav.tsx'
import SportLayout, { useCapabilities } from './layouts/SportLayout.tsx'
import Explore from './pages/sports/Explore.tsx'
import Game from './pages/sports/Game.tsx'
import Overview from './pages/sports/game/Overview.tsx'
import Situations from './pages/sports/game/Situations.tsx'
import Market from './pages/sports/Market.tsx'
import Markets from './pages/sports/Markets.tsx'
import News from './pages/sports/News.tsx'
import Placeholder from './pages/sports/Placeholder.tsx'
import Player from './pages/sports/Player.tsx'
import Players from './pages/sports/Players.tsx'
import Pulse from './pages/sports/Pulse.tsx'
import Slate from './pages/sports/Slate.tsx'
import SportHome from './pages/sports/SportHome.tsx'
import Team from './pages/sports/Team.tsx'
import Teams from './pages/sports/Teams.tsx'

// A sport with the Pulse's marts gets the Pulse as its home; one without keeps
// the diagnostics page (NCAAF today). Capabilities decide, never the name.
function SportIndex() {
  const caps = useCapabilities()
  if (!caps) return null
  const hasPulse = PULSE_CAPS.every((c) => caps.capabilities.includes(c))
  return hasPulse ? <Pulse /> : <SportHome />
}

// The sport lives in the path: /nfl/... and /ncaaf/... are different pages that
// share components. Page routes are added under /:sport as their phases land;
// each page gates itself on the sport's capabilities.
export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Navigate to="/nfl" replace />} />
        <Route path="/:sport" element={<SportLayout />}>
          <Route index element={<SportIndex />} />
          <Route path="slate" element={<Slate />} />
          {/* the game family: overview lands, the other rooms are tabs */}
          <Route path="games/:gameKey" element={<Overview />} />
          <Route path="games/:gameKey/props" element={<Game />} />
          <Route path="games/:gameKey/situations" element={<Situations />} />
          <Route path="games/:gameKey/lines" element={<Market family />} />
          <Route path="teams" element={<Teams />} />
          <Route path="teams/:team" element={<Team />} />
          <Route path="players" element={<Players />} />
          <Route path="players/:playerKey" element={<Player />} />
          <Route path="markets" element={<Markets />} />
          <Route path="markets/:gameKey" element={<Market />} />
          <Route path="news" element={<News />} />
          <Route path="explore" element={<Explore />} />
          <Route path="*" element={<Placeholder title="Not found" phase="" />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
