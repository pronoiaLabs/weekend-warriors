import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import SportLayout from './layouts/SportLayout.tsx'
import Game from './pages/sports/Game.tsx'
import Market from './pages/sports/Market.tsx'
import Markets from './pages/sports/Markets.tsx'
import News from './pages/sports/News.tsx'
import Placeholder from './pages/sports/Placeholder.tsx'
import Player from './pages/sports/Player.tsx'
import Players from './pages/sports/Players.tsx'
import Slate from './pages/sports/Slate.tsx'
import SportHome from './pages/sports/SportHome.tsx'
import Team from './pages/sports/Team.tsx'
import Teams from './pages/sports/Teams.tsx'

// The sport lives in the path: /nfl/... and /ncaaf/... are different pages that
// share components. Page routes are added under /:sport as their phases land;
// each page gates itself on the sport's capabilities.
export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Navigate to="/nfl" replace />} />
        <Route path="/:sport" element={<SportLayout />}>
          <Route index element={<SportHome />} />
          <Route path="slate" element={<Slate />} />
          <Route path="games/:gameKey" element={<Game />} />
          <Route path="teams" element={<Teams />} />
          <Route path="teams/:team" element={<Team />} />
          <Route path="players" element={<Players />} />
          <Route path="players/:playerKey" element={<Player />} />
          <Route path="markets" element={<Markets />} />
          <Route path="markets/:gameKey" element={<Market />} />
          <Route path="news" element={<News />} />
          <Route path="explore" element={<Placeholder title="Explorer" phase="Phase 4" />} />
          <Route path="*" element={<Placeholder title="Not found" phase="" />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
