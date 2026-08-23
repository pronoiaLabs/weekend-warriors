import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import SportLayout from './layouts/SportLayout.tsx'
import SportHome from './pages/sports/SportHome.tsx'
import Placeholder from './pages/sports/Placeholder.tsx'

// The sport lives in the path: /nfl/... and /ncaaf/... are different pages that
// share components. Page routes are added under /:sport as their phases land;
// SportLayout gates them on the sport's capabilities.
export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Navigate to="/nfl" replace />} />
        <Route path="/:sport" element={<SportLayout />}>
          <Route index element={<SportHome />} />
          <Route path="slate" element={<Placeholder title="Game day board" phase="Phase 3" />} />
          <Route path="explore" element={<Placeholder title="Explorer" phase="Phase 4" />} />
          <Route path="*" element={<Placeholder title="Not found" phase="" />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
