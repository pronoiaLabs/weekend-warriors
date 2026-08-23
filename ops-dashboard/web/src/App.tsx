import { BrowserRouter, Navigate, Route, Routes, useLocation, useParams } from 'react-router-dom'
import OpsLayout from './layouts/OpsLayout.tsx'
import Builds from './pages/Builds.tsx'
import Dashboard from './pages/Dashboard.tsx'
import DbtBuildDetail from './pages/DbtBuildDetail.tsx'
import PipelinesRecords from './pages/PipelinesRecords.tsx'
import PipelineDetail from './pages/PipelineDetail.tsx'
import RunDetail from './pages/RunDetail.tsx'

/** Old bookmarks keep working: the dbt index moved to /builds, the ingestion
    index to /pipelines, and pipeline detail pages to /ingestion/. Each carries
    its query string, sport filter and all. */
function Redirect({ to }: { to: string }) {
  const { search } = useLocation()
  return <Navigate to={{ pathname: to, search }} replace />
}

function LegacyPipelineDetailRedirect() {
  const { sport = '', name = '' } = useParams()
  return <Redirect to={`/ingestion/${sport}/${name}`} />
}

/** Every page renders inside OpsLayout: one shell, one dock, one sport filter. */
export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<OpsLayout />}>
          <Route path="/" element={<Dashboard />} />
          <Route path="/ingestion" element={<Redirect to="/pipelines" />} />
          <Route path="/ingestion/:sport/:name" element={<PipelineDetail />} />
          <Route path="/runs/:queryId" element={<RunDetail />} />
          <Route path="/builds" element={<Builds />} />
          <Route path="/dbt" element={<Redirect to="/builds" />} />
          <Route path="/dbt/builds/:buildId" element={<DbtBuildDetail />} />
          <Route path="/pipelines" element={<PipelinesRecords />} />
          <Route path="/pipelines/:sport/:name" element={<LegacyPipelineDetailRedirect />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
