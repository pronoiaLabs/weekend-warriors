import { BrowserRouter, Navigate, Route, Routes, useLocation, useParams } from 'react-router-dom'
import DbtBuildDetail from './pages/DbtBuildDetail.tsx'
import DbtBuilds from './pages/DbtBuilds.tsx'
import Fleet from './pages/Fleet.tsx'
import Incidents from './pages/Incidents.tsx'
import Pipelines from './pages/Pipelines.tsx'
import PipelineDetail from './pages/PipelineDetail.tsx'
import RunDetail from './pages/RunDetail.tsx'

/** The section renamed /pipelines -> /ingestion; old bookmarks and mid-session
    tabs keep working through these, sport filter and all. */
function LegacyPipelinesRedirect() {
  const { search } = useLocation()
  return <Navigate to={{ pathname: '/ingestion', search }} replace />
}

function LegacyPipelineDetailRedirect() {
  const { sport = '', name = '' } = useParams()
  const { search } = useLocation()
  return <Navigate to={{ pathname: `/ingestion/${sport}/${name}`, search }} replace />
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Fleet />} />
        <Route path="/ingestion" element={<Pipelines />} />
        <Route path="/ingestion/:sport/:name" element={<PipelineDetail />} />
        <Route path="/incidents" element={<Incidents />} />
        <Route path="/runs/:queryId" element={<RunDetail />} />
        <Route path="/dbt" element={<DbtBuilds />} />
        <Route path="/dbt/builds/:buildId" element={<DbtBuildDetail />} />
        <Route path="/pipelines" element={<LegacyPipelinesRedirect />} />
        <Route path="/pipelines/:sport/:name" element={<LegacyPipelineDetailRedirect />} />
      </Routes>
    </BrowserRouter>
  )
}
