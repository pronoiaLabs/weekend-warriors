import { TopBar } from '../components/TopBar.tsx'
import { EmptyState } from '../components/QuietNote.tsx'

export default function Incidents() {
  return (
    <>
      <TopBar />
      <main className="wrap">
        <h1>Incidents</h1>
        <EmptyState message="Incident feed lands in a later phase" />
      </main>
    </>
  )
}
