import { useEffect, useRef } from 'react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import { fetchSlate } from '../../api/sports/client.ts'
import type { SlatePayload, SlateRow, WeekRef } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useElementScrollMemory } from '../../hooks/useScrollMemory.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, signed, slotLabel, spreadText, tone } from '../../lib/format.ts'
import { useView, viewFromParams, viewToParams } from '../../state/view.tsx'

const WIND_FLAG = 10
const WIND_PASSING = 12
const PRECIP_FLAG = 0.2

export default function Slate() {
  return (
    <CapabilityGate cap="schedule">
      <SlateBoard />
    </CapabilityGate>
  )
}

function SlateBoard() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const [search, setSearch] = useSearchParams()
  const { view, replaceView } = useView()

  // Every choice lives in the URL: the API resolves what is absent (current
  // season, the week in progress, the default book), so a bare /nfl/slate is
  // always "this week at the default book" and a full URL is shareable. Keys
  // the URL lacks are filled from the remembered view (so Back from a game
  // where you switched books shows that book), and a choice made here replaces
  // the memory outright, so choosing the default again is remembered as such.
  useEffect(() => {
    const fromUrl = viewFromParams(search)
    const merged = { ...view, ...fromUrl }
    if (viewToParams(merged).toString() !== viewToParams(fromUrl).toString()) {
      const next = new URLSearchParams(search)
      for (const [k, v] of viewToParams(merged)) next.set(k, v)
      setSearch(next, { replace: true })
      return
    }
    replaceView(fromUrl)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search])

  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : undefined
  const seasonType = search.get('season_type') ?? undefined
  const weekParam = search.get('week')
  const week = weekParam ? Number(weekParam) : undefined
  const vendor = search.get('vendor') ?? undefined
  const outdoor = search.get('outdoor') === '1'

  const slate = useApi(
    (signal) => fetchSlate(sport, { season, season_type: seasonType, week, vendor }, signal),
    [sport, season, seasonType, week, vendor],
  )

  const set = (patch: Record<string, string | undefined>) => {
    const next = new URLSearchParams(search)
    for (const [k, v] of Object.entries(patch)) {
      if (v === undefined || v === '') next.delete(k)
      else next.set(k, v)
    }
    replaceView(viewFromParams(next)) // before the URL changes, so the effect does not refill
    setSearch(next, { replace: true })
  }

  const data = slate.data
  const label = caps?.label ?? sport.toUpperCase()

  return (
    <div className="page page-slate">
      <div className="page-head">
        <h1>Game day board</h1>
        <p className="lede">
          {data
            ? `${data.season_type_name} week ${data.week}, ${label} ${data.season}. One column per kickoff slot; the board scrolls, the slots stay aligned.`
            : slate.error
              ? slate.error
              : 'Loading the week...'}
        </p>
      </div>

      {data && <Kpis data={data} outdoor={outdoor} />}

      <div className="filters">
        {data && <WeekPicker data={data} onPick={set} />}
        <button
          type="button"
          className={`chip ${outdoor ? 'on' : ''}`}
          aria-pressed={outdoor}
          onClick={() => set({ outdoor: outdoor ? undefined : '1' })}
        >
          Outdoor only
        </button>
        {caps && caps.vendors.length > 0 && (
          <Chips
            label="Book"
            items={caps.vendors.map((v) => ({ id: v, label: v }))}
            active={data?.vendor ?? vendor ?? caps.default_vendor}
            onPick={(id) => set({ vendor: id === caps.default_vendor ? undefined : id })}
          />
        )}
        <span className="hint">Click a game for the prop board.</span>
      </div>

      {slate.error && !data && (
        <section className="tile">
          <header className="tile-head">
            <h2>Nothing to show</h2>
          </header>
          <p className="hint">{slate.error}</p>
        </section>
      )}

      {data && <Board data={data} outdoor={outdoor} sport={sport} vendorParam={vendor} />}

      <TileFrame title="How this board is built" className="note-tile" query={data?.query}>
        <p>
          Two selects on the game slate mart. The first lists the season's weeks with their kickoff
          span, which resolves the week in progress when the URL names none. The second reads the
          chosen week across every book and the API keeps one card per game with the selected book's
          closing line; a game that book has not priced keeps its card with the line blank. Weather,
          props open and news counts are columns on the same row.
        </p>
      </TileFrame>
    </div>
  )
}

/** Season type and week chips over a payload's week list; the markets board
    uses it over the weeks with a line. */
export function WeekPicker({
  data,
  onPick,
}: {
  data: { weeks: WeekRef[]; season_type_name: string; week: number }
  onPick: (patch: Record<string, string | undefined>) => void
}) {
  const types: string[] = []
  for (const w of data.weeks) if (!types.includes(w.season_type_name)) types.push(w.season_type_name)
  const weeks = data.weeks.filter((w) => w.season_type_name === data.season_type_name)
  return (
    <>
      <Chips
        label="Season type"
        items={types.map((t) => ({ id: t, label: t }))}
        active={data.season_type_name}
        onPick={(id) => onPick({ season_type: id, week: undefined })}
      />
      <Chips
        label="Week"
        items={weeks.map((w) => ({ id: String(w.week), label: weekLabel(w) }))}
        active={String(data.week)}
        onPick={(id) => onPick({ season_type: data.season_type_name, week: id })}
      />
    </>
  )
}

function weekLabel(w: WeekRef): string {
  const done = w.completed === w.games ? ' ✓' : w.completed > 0 ? ` ${w.completed}/${w.games}` : ''
  return `W${w.week}${done}`
}

function weatherFlagged(g: SlateRow): boolean {
  return Boolean(g.is_weather_relevant) && ((g.wind_mph ?? 0) >= WIND_FLAG || (g.precip_in ?? 0) > 0)
}

function Kpis({ data, outdoor }: { data: SlatePayload; outdoor: boolean }) {
  const all = data.rows
  const shown = outdoor ? all.filter((g) => g.is_weather_relevant) : all
  const forecasts = all.filter((g) => g.kickoff_temp_f !== null).length
  const moves = all.filter((g) => g.home_spread_movement !== null)
  const biggest = moves.length
    ? moves.reduce((a, b) => (Math.abs(b.home_spread_movement!) > Math.abs(a.home_spread_movement!) ? b : a))
    : null
  const props = all.reduce((n, g) => n + g.props_open, 0)
  const propsAll = all.reduce((n, g) => n + g.props_open_all_books, 0)
  const newsGames = all.filter((g) => g.news_mentions_7d > 0).length
  const completed = all.filter((g) => g.is_completed).length
  const lined = all.filter((g) => g.vendor !== null).length

  return (
    <div className="kpis five">
      <div className="kpi">
        <span className="l">Games</span>
        <span className="v">{shown.length}</span>
        <span className="s">
          {completed ? `${completed} of ${all.length} final` : outdoor ? `${all.length} on the slate` : 'none played yet'}
        </span>
      </div>
      <div className="kpi">
        <span className="l">Weather relevant</span>
        <span className="v">{forecasts ? all.filter(weatherFlagged).length : 'n/a'}</span>
        <span className="s">{forecasts ? `wind ${WIND_FLAG}+ mph or precipitation` : 'no forecast yet for this week'}</span>
      </div>
      <div className="kpi">
        <span className="l">Biggest line move</span>
        <span className="v">{biggest ? signed(biggest.home_spread_movement, 1) : 'n/a'}</span>
        <span className="s">
          {biggest
            ? `${biggest.away_team_label} at ${biggest.home_team_label}, ${data.vendor}`
            : lined
              ? 'no opening line recorded yet'
              : `no ${data.vendor ?? ''} lines this week`}
        </span>
      </div>
      <div className="kpi">
        <span className="l">Props open</span>
        <span className="v">{data.vendor ? fmt(props) : 'n/a'}</span>
        <span className="s">{data.vendor ? `at ${data.vendor}; ${fmt(propsAll)} across all books` : 'no props feed'}</span>
      </div>
      <div className="kpi">
        <span className="l">Games with news</span>
        <span className="v">{newsGames}</span>
        <span className="s">player mentions in the seven days before kickoff</span>
      </div>
    </div>
  )
}

function Board({
  data,
  outdoor,
  sport,
  vendorParam,
}: {
  data: SlatePayload
  outdoor: boolean
  sport: string
  vendorParam: string | undefined
}) {
  const games = outdoor ? data.rows.filter((g) => g.is_weather_relevant) : data.rows
  const slots: string[] = []
  for (const g of games) if (!slots.includes(g.kickoff_slot_et)) slots.push(g.kickoff_slot_et)
  // the board scrolls on its own, so the browser cannot restore it; remember
  // per URL so Back from a game lands on the same slot
  const boardRef = useRef<HTMLDivElement>(null)
  const { pathname, search } = useLocation()
  useElementScrollMemory(boardRef, `${pathname}${search}`, games.length > 0)
  if (games.length === 0) {
    return (
      <section className="tile">
        <p className="hint">No {outdoor ? 'outdoor ' : ''}games in this week.</p>
      </section>
    )
  }
  return (
    <div className="board" ref={boardRef}>
      <div className="slots" style={{ '--n': slots.length } as React.CSSProperties}>
        {slots.map((slot) => (
          <div className="slot" key={slot}>
            <h3 className="slot-head">{slotLabel(slot)} ET</h3>
            <div className="slot-games">
              {games
                .filter((g) => g.kickoff_slot_et === slot)
                .map((g) => (
                  <GameCard key={g.game_key} g={g} sport={sport} vendorParam={vendorParam} />
                ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

function GameCard({ g, sport, vendorParam }: { g: SlateRow; sport: string; vendorParam: string | undefined }) {
  const href = `/${sport}/games/${g.game_key}${vendorParam ? `?vendor=${encodeURIComponent(vendorParam)}` : ''}`
  const hasLine = g.vendor !== null && g.home_spread !== null
  const hasForecast = g.kickoff_temp_f !== null || g.wind_mph !== null || g.precip_in !== null
  const flags: { cls: string; text: string }[] = []
  if (g.props_open > 0) flags.push({ cls: 'props', text: `${g.props_open} props open` })
  else if (g.props_open_all_books > 0) flags.push({ cls: 'props', text: `${g.props_open_all_books} props at other books` })
  if (g.news_mentions_7d > 0)
    flags.push({ cls: 'news', text: `${g.news_mentions_7d} news mention${g.news_mentions_7d === 1 ? '' : 's'}, ${g.players_in_news_7d} player${g.players_in_news_7d === 1 ? '' : 's'}` })
  if (g.is_weather_relevant && (g.wind_mph ?? 0) >= WIND_PASSING) flags.push({ cls: 'wx', text: `Wind ${fmt(g.wind_mph)} mph, passing props flagged` })
  if (g.is_weather_relevant && (g.precip_in ?? 0) >= PRECIP_FLAG) flags.push({ cls: 'wx', text: `Rain ${fmt(g.precip_in, 2)} in` })
  if (g.is_international) flags.push({ cls: '', text: 'International' })

  return (
    <Link className="game" to={href} data-tilt="">
      <div className="game-teams">
        <div className="team away">
          <span className="abbr">{g.away_team_label}</span>
          <span className="name">{g.away_team_name}</span>
        </div>
        <div className="at">at</div>
        <div className="team home">
          <span className="abbr">{g.home_team_label}</span>
          <span className="name">{g.home_team_name}</span>
        </div>
      </div>

      {g.is_completed ? (
        <div className="game-line">
          <div className="ln">
            <span className="v">
              {fmt(g.away_score)} <small>{g.away_team_label}</small>
            </span>
            <span className="l">Final{g.went_to_overtime ? ' (OT)' : ''}</span>
          </div>
          <div className="ln">
            <span className="v">
              {fmt(g.home_score)} <small>{g.home_team_label}</small>
            </span>
            <span className="l">&nbsp;</span>
          </div>
          <div className="ln">
            <span className="v">{g.home_spread_result ? `${g.home_team_label} ${g.home_spread_result}` : hasLine ? spreadText(g.home_spread) : ''}</span>
            <span className="l">{g.total_result ? `Total ${g.total_result}` : hasLine ? 'Closing spread' : 'No line'}</span>
          </div>
        </div>
      ) : hasLine ? (
        <div className="game-line">
          <div className="ln">
            <span className="v">
              {g.home_team_label} {spreadText(g.home_spread)}
            </span>
            <span className="l">Spread</span>
          </div>
          <div className="ln">
            <span className="v">{fmt(g.total_line, 1)}</span>
            <span className="l">Total</span>
          </div>
          <div className={`ln ${tone(g.home_spread_movement)}`}>
            <span className="v">{g.home_spread_movement === null ? 'open' : signed(g.home_spread_movement, 1)}</span>
            <span className="l">Move</span>
          </div>
        </div>
      ) : (
        <div className="game-line none">
          {g.vendors_available.length ? `No line at ${vendorParam ?? 'this book'}; priced at ${g.vendors_available.join(', ')}` : 'No line yet'}
        </div>
      )}

      {hasForecast ? (
        <div className="game-wx">
          <div className="wx">
            <span className="v">
              {fmt(g.kickoff_temp_f)}
              <small>F</small>
            </span>
            <span className="l">Kickoff</span>
          </div>
          <div className={`wx ${(g.wind_mph ?? 0) >= WIND_FLAG ? 'warn' : ''}`}>
            <span className="v">
              {fmt(g.wind_mph)}
              <small>mph</small>
            </span>
            <span className="l">Wind</span>
          </div>
          <div className={`wx ${(g.precip_in ?? 0) > 0 ? 'warn' : ''}`}>
            <span className="v">
              {fmt(g.precip_in, 2)}
              <small>in</small>
            </span>
            <span className="l">Precip</span>
          </div>
        </div>
      ) : (
        <div className="game-wx none">{g.is_weather_relevant ? 'Forecast arrives inside the week' : 'Indoors'}</div>
      )}

      <div className="game-venue">
        <span>{g.stadium_name ?? g.venue ?? ''}</span>
        <span className="roof">{g.roof ?? ''}</span>
      </div>

      {flags.length > 0 && (
        <div className="ready">
          {flags.map((f) => (
            <span key={f.text} className={`flag ${f.cls}`}>
              {f.text}
            </span>
          ))}
        </div>
      )}
    </Link>
  )
}
