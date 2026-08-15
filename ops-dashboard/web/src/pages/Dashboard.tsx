import { useEffect, useState } from 'react'
import { fetchHeadlines, fetchPipelinesIndex, fetchSlate } from '../api/client.ts'
import type { HeadlinesPayload, PipelineIndexRow, SlatePayload } from '../api/types.ts'
import { EmptyState } from '../components/QuietNote.tsx'
import { Chrome } from '../components/slate/Chrome.tsx'
import { HeadlinesPanel } from '../components/slate/HeadlinesPanel.tsx'
import { LeagueRow } from '../components/slate/LeagueRow.tsx'
import { RecordsPanel } from '../components/slate/RecordsPanel.tsx'
import { useDayParam } from '../hooks/useDayParam.ts'
import { useSportFilter } from '../hooks/useSportFilter.ts'

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export default function Dashboard() {
  const { sport } = useSportFilter()
  const { day, setDay } = useDayParam()
  const [slate, setSlate] = useState<SlatePayload | null>(null)
  const [wire, setWire] = useState<HeadlinesPayload | null>(null)
  const [pipelines, setPipelines] = useState<PipelineIndexRow[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const control = new AbortController()
    setError(null)
    setSlate(null)
    fetchSlate(sport, day, control.signal)
      .then(setSlate)
      .catch((cause: unknown) => {
        if (!isAbort(cause)) setError(message(cause))
      })
    return () => control.abort()
  }, [sport, day])

  useEffect(() => {
    const control = new AbortController()
    setWire(null)
    fetchHeadlines(day, control.signal)
      .then(setWire)
      // The wire is commentary on the slate, so the page still stands without it.
      .catch(() => undefined)
    return () => control.abort()
  }, [day])

  useEffect(() => {
    const control = new AbortController()
    setPipelines([])
    fetchPipelinesIndex(sport, control.signal)
      .then((payload) => setPipelines(payload.pipelines))
      .catch(() => undefined)
    return () => control.abort()
  }, [sport])

  if (error) {
    return (
      <>
        <Chrome />
        <main className="sl-page">
          <EmptyState message="Could not load the slate" detail={error} bad />
        </main>
      </>
    )
  }

  if (!slate) {
    return (
      <>
        <Chrome />
        <main className="sl-page">
          <EmptyState message="Loading the slate" />
        </main>
      </>
    )
  }

  // Today is the default view, so selecting it clears ?date= rather than pinning
  // a date that would go stale in a tab left open overnight.
  const today = slate.days.find((entry) => entry.is_today)?.date ?? null

  return (
    <>
      <Chrome
        now={slate.now}
        days={slate.days}
        selected={slate.date}
        onSelect={(date) => setDay(date === today ? null : date)}
      />
      <main className="sl-page split">
        <div>
          {slate.leagues.length > 0 ? (
            slate.leagues.map((league) => <LeagueRow key={league.sport} league={league} />)
          ) : (
            <EmptyState message="Nothing on the slate for this day" />
          )}
        </div>
        <aside className="sl-rail">
          <HeadlinesPanel wire={wire} />
          <RecordsPanel rows={pipelines} />
        </aside>
      </main>
    </>
  )
}
