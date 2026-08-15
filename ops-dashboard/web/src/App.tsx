import { BrowserRouter, Navigate, Route, Routes, useLocation, useParams } from 'react-router-dom'
import Builds from './pages/Builds.tsx'
import Dashboard from './pages/Dashboard.tsx'
import DbtBuildDetail from './pages/DbtBuildDetail.tsx'
import PipelinesRecords from './pages/PipelinesRecords.tsx'
import PipelineDetail from './pages/PipelineDetail.tsx'
import RunDetail from './pages/RunDetail.tsx'

/** The dbt section renamed /dbt -> /builds. The build detail pages keep their
    /dbt/builds/ prefix, so only the index moves. */
function LegacyDbtRedirect() {
  const { search } = useLocation()
  return <Navigate to={{ pathname: '/builds', search }} replace />
}

/** The ingestion index is gone; /pipelines is the one pipeline list now. Only
    the index moves: the /ingestion/:sport/:name detail pages stay where they
    are, which is why this redirect is bound to the exact path. */
function LegacyIngestionIndexRedirect() {
  const { search } = useLocation()
  return <Navigate to={{ pathname: '/pipelines', search }} replace />
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
        <Route path="/ingestion" element={<LegacyIngestionIndexRedirect />} />
        <Route path="/ingestion/:sport/:name" element={<PipelineDetail />} />
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
