import { useParams } from 'react-router-dom'
import { TopBar } from '../components/TopBar.tsx'
import { EmptyState } from '../components/QuietNote.tsx'

export default function PipelineDetail() {
  const { sport, name } = useParams()
  return (
    <>
      <TopBar />
      <main className="wrap">
        <h1>{name}</h1>
        <EmptyState message="Pipeline detail lands in a later phase" detail={`${sport}/${name}`} />
      </main>
    </>
  )
}
