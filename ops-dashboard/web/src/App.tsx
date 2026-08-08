import { BrowserRouter, Route, Routes } from 'react-router-dom'
import Fleet from './pages/Fleet.tsx'
import Incidents from './pages/Incidents.tsx'
import PipelineDetail from './pages/PipelineDetail.tsx'
import RunDetail from './pages/RunDetail.tsx'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Fleet />} />
        <Route path="/incidents" element={<Incidents />} />
        <Route path="/pipelines/:sport/:name" element={<PipelineDetail />} />
        <Route path="/runs/:queryId" element={<RunDetail />} />
      </Routes>
    </BrowserRouter>
  )
}
