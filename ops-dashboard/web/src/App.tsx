import { BrowserRouter, Route, Routes } from 'react-router-dom'

function Fleet() {
  return <p>Fleet overview - coming in phase 4</p>
}

function Incidents() {
  return <p>Incidents - coming in a later phase</p>
}

function PipelineDetail() {
  return <p>Pipeline detail - coming in a later phase</p>
}

function RunDetail() {
  return <p>Run detail - coming in a later phase</p>
}

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
