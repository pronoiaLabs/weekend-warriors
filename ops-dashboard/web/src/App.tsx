import { BrowserRouter, Route, Routes } from 'react-router-dom'
import DbtBuildDetail from './pages/DbtBuildDetail.tsx'
import DbtBuilds from './pages/DbtBuilds.tsx'
import Fleet from './pages/Fleet.tsx'
import Incidents from './pages/Incidents.tsx'
import Pipelines from './pages/Pipelines.tsx'
import PipelineDetail from './pages/PipelineDetail.tsx'
import RunDetail from './pages/RunDetail.tsx'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Fleet />} />
        <Route path="/incidents" element={<Incidents />} />
        <Route path="/pipelines" element={<Pipelines />} />
        <Route path="/pipelines/:sport/:name" element={<PipelineDetail />} />
        <Route path="/runs/:queryId" element={<RunDetail />} />
        <Route path="/dbt" element={<DbtBuilds />} />
        <Route path="/dbt/builds/:buildId" element={<DbtBuildDetail />} />
      </Routes>
    </BrowserRouter>
  )
}
