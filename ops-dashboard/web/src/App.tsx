import { BrowserRouter, Navigate, Route, Routes, useLocation, useParams } from 'react-router-dom'
import Builds from './pages/Builds.tsx'
import Dashboard from './pages/Dashboard.tsx'
import DbtBuildDetail from './pages/DbtBuildDetail.tsx'
import Incidents from './pages/Incidents.tsx'
import Pipelines from './pages/Pipelines.tsx'
import PipelinesRecords from './pages/PipelinesRecords.tsx'
import PipelineDetail from './pages/PipelineDetail.tsx'
import RunDetail from './pages/RunDetail.tsx'

/** The dbt section renamed /dbt -> /builds. The build detail pages keep their
    /dbt/builds/ prefix, so only the index moves. */
function LegacyDbtRedirect() {
  const { search } = useLocation()
  return <Navigate to={{ pathname: '/builds', search }} replace />
}

/** The pipeline detail pages renamed /pipelines/... -> /ingestion/...; old
    bookmarks and mid-session tabs keep working, sport filter and all. */
function LegacyPipelineDetailRedirect() {
  const { sport = '', name = '' } = useParams()
  const { search } = useLocation()
  return <Navigate to={{ pathname: `/ingestion/${sport}/${name}`, search }} replace />
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/ingestion" element={<Pipelines />} />
        <Route path="/ingestion/:sport/:name" element={<PipelineDetail />} />
        <Route path="/incidents" element={<Incidents />} />
        <Route path="/runs/:queryId" element={<RunDetail />} />
        <Route path="/builds" element={<Builds />} />
        <Route path="/dbt" element={<LegacyDbtRedirect />} />
        <Route path="/dbt/builds/:buildId" element={<DbtBuildDetail />} />
        <Route path="/pipelines" element={<PipelinesRecords />} />
        <Route path="/pipelines/:sport/:name" element={<LegacyPipelineDetailRedirect />} />
      </Routes>
    </BrowserRouter>
  )
}
