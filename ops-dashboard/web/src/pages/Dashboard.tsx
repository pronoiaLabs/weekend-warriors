import { useEffect } from 'react'
import { fetchHeadlines, fetchPipelinesIndex, fetchSlate } from '../api/client.ts'
import type { SlatePayload } from '../api/types.ts'
import Chips from '../components/Chips.tsx'
import { DayStrip } from '../components/slate/DayStrip.tsx'
import { HeadlinesPanel } from '../components/slate/HeadlinesPanel.tsx'
import { LeagueRow } from '../components/slate/LeagueRow.tsx'
import { RecordsPanel } from '../components/slate/RecordsPanel.tsx'
import TileFrame from '../components/TileFrame.tsx'
import { useApi } from '../hooks/useApi.ts'
import { useDayParam } from '../hooks/useDayParam.ts'
import { useSlateFilters } from '../hooks/useSlateFilters.ts'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { useChrome } from '../state/chrome.tsx'
import { compact, longDayTitle, num } from '../utils/format.ts'
import {
  filterLeagues,
  KIND_LABELS,
  kindCounts,
  SLATE_KINDS,
  SLATE_VIEWS,
  VIEW_LABELS,
  viewCounts,
} from '../utils/slateView.ts'

/** One day of the schedule read as a scoreboard: score cards grouped by league,
    the surrounding week as a day rail, the AI wire and the worst records in
    the side rail. The day, the sport and the view chips live in the URL; today
    and "all" stay out of it so a tab left open overnight does not pin stale
    defaults. */
export default function Dashboard() {
  const { sport } = useSportFilter()
  const { day, setDay } = useDayParam()
  const { view, kind, setView, setKind } = useSlateFilters()
  const { setNow } = useChrome()

  const slate = useApi((signal) => fetchSlate(sport, day, signal), [sport, day])
  // the wire is commentary on the slate and the records a teaser: the page stands without either
  const wire = useApi((signal) => fetchHeadlines(day, signal), [day])
  const index = useApi((signal) => fetchPipelinesIndex(sport, signal), [sport])

  useEffect(() => {
    setNow(slate.data?.now ?? null)
    return () => setNow(null)
  }, [slate.data?.now, setNow])

  const data = slate.data
  const today = data?.days.find((d) => d.is_today)?.date ?? null
  const selected = data?.days.find((d) => d.date === data.date) ?? null
  const filtering = view !== 'all' || kind !== 'all'
  const shown = data ? filterLeagues(data.leagues, view, kind) : []
  const views = data ? viewCounts(data.leagues) : null
  const kinds = data ? kindCounts(data.leagues) : null

  return (
    <div className="page page-dashboard">
      <div className="page-head">
        <h1>Dashboard</h1>
        <p className="lede">
          {data
            ? `${longDayTitle(data.date)}${sport === 'all' ? '' : `, ${sport}`}. Every cron slot of the day as a score card: what ran, what failed, what never fired and what is still ahead, with the dbt builds that data landing set off.`
            : slate.error
              ? slate.error
              : 'Loading the slate...'}
        </p>
      </div>

      {data && selected && <Kpis data={data} day={selected} />}

      <div className="dash-body">
        {data && (
          <aside className="day-rail">
            <DayStrip days={data.days} selected={data.date} onSelect={(date) => setDay(date === today ? null : date)} />
          </aside>
        )}

        <div className="dash-main">
          {data && views && kinds && (
            <div className="filters slate-filters">
              <Chips
                label="Show"
                active={view}
                onPick={(id) => setView(id as typeof view)}
                items={SLATE_VIEWS.map((id) => ({
                  id,
                  label: `${VIEW_LABELS[id]} · ${views[id]}`,
                  bad: id === 'failed' || id === 'missing' ? views[id] > 0 : false,
                  warn: id === 'missed' && views[id] > 0,
                }))}
              />
              <Chips
                label="Kind"
                active={kind}
                onPick={(id) => setKind(id as typeof kind)}
                items={SLATE_KINDS.filter((id) => id === 'all' || kinds[id] > 0).map((id) => ({
                  id,
                  label: `${KIND_LABELS[id]} · ${kinds[id]}`,
                }))}
              />
            </div>
          )}
          <div className="filters">
            <span className="slot-legend" aria-label="What the colours mean">
              <span>
                <i className="st st-succeeded" /> final
              </span>
              <span>
                <i className="st st-failure" /> failed
              </span>
              <span>
                <i className="st st-missed" /> no show: the slot passed, nothing fired
              </span>
              <span>
                <i className="st st-missing" /> ran but never recorded itself
              </span>
              <span>
                <i className="st st-upcoming" /> still ahead
              </span>
            </span>
          </div>

          {slate.error && !data && (
            <section className="tile">
              <header className="tile-head">
                <h2>Could not load the slate</h2>
              </header>
              <p className="hint">{slate.error}</p>
            </section>
          )}

          {data && (
            <div className="grid cols-slate">
              <div>
                {shown.length > 0 ? (
                  shown.map((league) => <LeagueRow key={league.sport} league={league} filtered={filtering} />)
                ) : (
                  <TileFrame title="Nothing on the slate" meta={data.date}>
                    <p className="hint">
                      {filtering
                        ? `No ${VIEW_LABELS[view].toLowerCase()} ${kind === 'all' ? 'jobs' : KIND_LABELS[kind].toLowerCase()} on this day for ${sport === 'all' ? 'any sport' : sport}.`
                        : `No slot, run or build on this day for ${sport === 'all' ? 'any sport' : sport}.`}
                    </p>
                  </TileFrame>
                )}
              </div>
              <aside className="rail">
                <HeadlinesPanel wire={wire.data} />
                <RecordsPanel rows={index.data?.pipelines ?? []} />
              </aside>
            </div>
          )}
        </div>
      </div>

      <TileFrame title="How this board is built" className="note-tile" query={data?.query}>
        <p>
          The registry says which pipelines exist and when they fire; the run table says what happened. The API
          expands each cron over the day, matches runs to slots, and emits one card per slot: final, failed, a
          no-show when the slot passed with no run row, or still ahead. A pipeline's slots begin when it did
          (the deploy that registered it or its first run, whichever came first), so the morning before a new
          Task existed is not a row of no-shows. dbt builds have no slot, so their league is whatever fired when
          data landed. The day rail tallies the same cards for the days around it; the chips hide the slots you
          are not looking for.
        </p>
      </TileFrame>
    </div>
  )
}

function Kpis({ data, day }: { data: SlatePayload; day: SlatePayload['days'][number] }) {
  const rows = data.leagues.reduce((n, l) => n + (l.rows_loaded ?? 0), 0)
  const builds = data.leagues.filter((l) => l.kind === 'dbt').reduce((n, l) => n + l.cards.length, 0)
  const failedBuilds = data.leagues.filter((l) => l.kind === 'dbt').reduce((n, l) => n + l.cards.filter((c) => c.state === 'failure').length, 0)
  return (
    <div className="kpis six">
      <div className="kpi">
        <span className="l">Ran</span>
        <span className="v">{day.ran}</span>
        <span className="s">of {day.slots} slots on the day</span>
      </div>
      <div className={`kpi ${day.failed ? 'bad' : 'good'}`}>
        <span className="l">Failed</span>
        <span className="v">{day.failed}</span>
        <span className="s">{day.failed ? 'runs that broke' : 'no run broke'}</span>
      </div>
      <div className={`kpi ${day.missed ? 'warn' : ''}`}>
        <span className="l">No show</span>
        <span className="v">{day.missed}</span>
        <span className="s">{day.missed ? 'slots that passed with nothing fired' : 'every slot so far fired'}</span>
      </div>
      <div className="kpi">
        <span className="l">Still ahead</span>
        <span className="v">{day.upcoming}</span>
        <span className="s">slots yet to fire</span>
      </div>
      <div className="kpi">
        <span className="l">Rows in</span>
        <span className="v">{compact(rows)}</span>
        <span className="s">{num(rows)} rows across the ingestion leagues</span>
      </div>
      <div className={`kpi ${failedBuilds ? 'bad' : ''}`}>
        <span className="l">dbt builds</span>
        <span className="v">{builds}</span>
        <span className="s">{failedBuilds ? `${failedBuilds} failed` : 'fired by data landing'}</span>
      </div>
    </div>
  )
}
