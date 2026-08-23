import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import SportLayout from './layouts/SportLayout.tsx'
import Game from './pages/sports/Game.tsx'
import Placeholder from './pages/sports/Placeholder.tsx'
import Slate from './pages/sports/Slate.tsx'
import SportHome from './pages/sports/SportHome.tsx'

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
          <Route path="explore" element={<Placeholder title="Explorer" phase="Phase 4" />} />
          <Route path="*" element={<Placeholder title="Not found" phase="" />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
