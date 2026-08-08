import { useParams } from 'react-router-dom'
import { TopBar } from '../components/TopBar.tsx'
import { EmptyState } from '../components/QuietNote.tsx'

export default function RunDetail() {
  const { queryId } = useParams()
  return (
    <>
      <TopBar />
      <main className="wrap">
        <h1>Run detail</h1>
        <EmptyState message="Run detail lands in a later phase" detail={queryId} />
      </main>
    </>
  )
}
