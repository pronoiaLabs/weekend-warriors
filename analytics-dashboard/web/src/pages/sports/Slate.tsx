import { useEffect, useRef } from 'react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import { fetchSlate } from '../../api/sports/client.ts'
import type { BrandingRow, SlatePayload, SlateRow, WeekRef } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import TeamLogo from '../../components/sports/TeamLogo.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBranding, teamAccent } from '../../hooks/useBranding.ts'
import { useElementScrollMemory } from '../../hooks/useScrollMemory.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, odds, signed, spreadText } from '../../lib/format.ts'
import { PRECIP_FLAG, SPREAD_MOVE_FLAG, WIND_FLAG, WIND_PASSING } from '../../lib/thresholds.ts'
import { useView, viewFromParams, viewToParams } from '../../state/view.tsx'

type Branding = Map<string, BrandingRow>

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

  const shown = data ? (outdoor ? data.rows.filter((g) => g.is_weather_relevant) : data.rows) : []
  const divisionGames = shown.filter((g) => g.is_division_game).length
  const pendingLines = shown.filter((g) => !g.is_completed && g.vendor === null).length

  return (
    <div className="page page-slate">
      <div className="page-head">
        <h1>Game day</h1>
        <p className="lede">
          {data
            ? `The ${data.season_type_name.toLowerCase()} week ${data.week} slate as a ledger — one line per game, grouped by kickoff window. Matchup, line, weather, official, availability: enough to decide which games are worth working before you open one.`
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
        {data && (
          <span className="hint">
            {shown.length} game{shown.length === 1 ? '' : 's'}
            {divisionGames > 0 ? ` · ${divisionGames} division` : ''}
            {pendingLines > 0 ? ` · ${pendingLines} waiting on a line` : ''}
          </span>
        )}
      </div>

      {slate.error && !data && (
        <section className="tile">
          <header className="tile-head">
            <h2>Nothing to show</h2>
          </header>
          <p className="hint">{slate.error}</p>
        </section>
      )}

      {data && <Ledger data={data} games={shown} outdoor={outdoor} sport={sport} vendorParam={vendor} />}

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

function Ledger({
  data,
  games,
  outdoor,
  sport,
  vendorParam,
}: {
  data: SlatePayload
  games: SlateRow[]
  outdoor: boolean
  sport: string
  vendorParam: string | undefined
}) {
  const branding = useBranding(sport)
  // group by named kickoff window, windows in chronological order, games in
  // kickoff order within each (the rows arrive ordered by kickoff already)
  const ordered = [...games].sort(
    (a, b) => a.kickoff_window_order - b.kickoff_window_order || a.game_datetime_et.localeCompare(b.game_datetime_et),
  )
  const windows: { key: string; label: string; games: SlateRow[] }[] = []
  for (const g of ordered) {
    const last = windows[windows.length - 1]
    if (last && last.key === g.kickoff_window) last.games.push(g)
    else windows.push({ key: g.kickoff_window, label: g.kickoff_window_label, games: [g] })
  }
  // the marquee: the biggest total on the board, only while the week is live
  const totals = games.filter((g) => !g.is_completed).map((g) => g.total_line ?? 0)
  const maxTotal = totals.length ? Math.max(...totals) : null

  // the ledger scrolls on its own, so the browser cannot restore it; remember
  // per URL so Back from a game lands on the same window
  const bodyRef = useRef<HTMLDivElement>(null)
  const { pathname, search } = useLocation()
  useElementScrollMemory(bodyRef, `${pathname}${search}`, games.length > 0)

  if (games.length === 0) {
    return (
      <section className="tile">
        <p className="hint">No {outdoor ? 'outdoor ' : ''}games in this week.</p>
      </section>
    )
  }
  return (
    <section className="tile ledger">
      <div className="tile-body" ref={bodyRef}>
        <div className="led">
          <div className="led-row head">
            <span>Matchup</span>
            <span>Spread</span>
            <span>Total</span>
            <span>Moneyline</span>
            <span>Weather</span>
            <span>Official</span>
            <span>Availability</span>
            <span>Flags</span>
          </div>
          {windows.map((w) => (
            <div key={w.key} className="led-window">
              <div className="led-slot">
                {w.label}
                <small>
                  · {w.games.length} game{w.games.length === 1 ? '' : 's'}
                </small>
              </div>
              {w.games.map((g) => (
                <LedgerRow
                  key={g.game_key}
                  g={g}
                  sport={sport}
                  vendorParam={vendorParam}
                  branding={branding}
                  marquee={maxTotal !== null && !g.is_completed && g.total_line !== null && g.total_line === maxTotal}
                  book={data.vendor}
                />
              ))}
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

const BOOK_SHORT: Record<string, string> = {
  draftkings: 'DK',
  fanduel: 'FD',
  betmgm: 'MGM',
  caesars: 'CZR',
  betrivers: 'BR',
  polymarket: 'POLY',
  kalshi: 'KAL',
}

function bookShort(vendor: string | null | undefined): string {
  if (!vendor) return ''
  return BOOK_SHORT[vendor] ?? vendor.toUpperCase().slice(0, 4)
}

function TeamCell({ label, record, row }: { label: string; record: string; row: BrandingRow | undefined }) {
  const accent = teamAccent(row)
  return (
    <span className="mu-t" style={accent ? ({ '--team': accent } as React.CSSProperties) : undefined}>
      <span className="r1">
        {row && <TeamLogo teamKey={row.team_key} label={label} branding={new Map([[row.team_key, row]])} />}
        <b>{label}</b>
        <small>{record}</small>
      </span>
      <span className="cu" />
    </span>
  )
}

function AvailabilityCell({ g }: { g: SlateRow }) {
  const side = (label: string, q: number | null, out: number | null) => {
    const bits = []
    if (out) bits.push(<span key="out" className="badge out">{out} OUT</span>)
    if (q) bits.push(<span key="q" className="badge q">{q} Q</span>)
    return bits.length ? (
      <span key={label} className="side">
        <span className="tm">{label}</span>
        {bits}
      </span>
    ) : null
  }
  if (g.home_players_out === null && g.away_players_out === null) {
    return (
      <span className="avc">
        <span className="clear">no report</span>
      </span>
    )
  }
  const both = [
    side(g.away_team_label, g.away_players_questionable, g.away_players_out),
    side(g.home_team_label, g.home_players_questionable, g.home_players_out),
  ].filter(Boolean)
  return <span className="avc">{both.length ? both : <span className="clear">no flags</span>}</span>
}

function LedgerRow({
  g,
  sport,
  vendorParam,
  branding,
  marquee,
  book,
}: {
  g: SlateRow
  sport: string
  vendorParam: string | undefined
  branding: Branding
  marquee: boolean
  book: string | null
}) {
  const href = `/${sport}/games/${g.game_key}${vendorParam ? `?vendor=${encodeURIComponent(vendorParam)}` : ''}`
  const hasLine = g.vendor !== null && (g.home_spread !== null || g.total_line !== null)
  const short = bookShort(g.vendor ?? book)

  // sided labels: the favorite carries the number
  const homeFav = (g.home_spread ?? 0) <= 0
  const spreadLabel =
    g.home_spread === null ? null : `${homeFav ? g.home_team_label : g.away_team_label} ${spreadText(homeFav ? g.home_spread : g.away_spread)}`
  const mlHome = g.home_moneyline_odds
  const mlAway = g.away_moneyline_odds
  const mlFavHome = mlHome !== null && mlAway !== null ? mlHome <= mlAway : homeFav
  const mlFav = mlFavHome ? mlHome : mlAway
  const mlOther = mlFavHome ? mlAway : mlHome

  const flags: { cls: string; text: string }[] = []
  if (g.is_division_game) flags.push({ cls: 'badge', text: 'Division' })
  if (marquee) flags.push({ cls: 'badge', text: '✦ Marquee' })
  if (!g.is_completed && Math.abs(g.home_spread_movement ?? 0) >= SPREAD_MOVE_FLAG)
    flags.push({ cls: 'props', text: `spread moved ${signed(g.home_spread_movement, 1)}` })
  if (g.is_weather_relevant && (g.wind_mph ?? 0) >= WIND_PASSING && g.total_line !== null)
    flags.push({ cls: 'wx', text: `✦ wind ${fmt(g.wind_mph)} vs ${fmt(g.total_line, 1)} total` })
  else if (g.is_weather_relevant && (g.precip_in ?? 0) >= PRECIP_FLAG)
    flags.push({ cls: 'wx', text: `rain ${fmt(g.precip_in, 2)} in` })
  if (!g.is_completed && g.props_open > 0) flags.push({ cls: 'props', text: `${g.props_open} props posted` })
  else if (!g.is_completed && g.props_open_all_books > 0)
    flags.push({ cls: 'props', text: `${g.props_open_all_books} props at other books` })
  if (g.news_mentions_7d > 0) flags.push({ cls: 'news', text: `${g.news_mentions_7d} news mentions` })
  if (g.is_international) flags.push({ cls: '', text: 'International' })

  return (
    <Link className={`led-row${marquee ? ' marquee' : ''}`} to={href}>
      <span className="mu">
        <span className="mu-teams">
          <TeamCell label={g.away_team_label} record={g.away_record} row={branding.get(g.away_team_key)} />
          <span className="at">at</span>
          <TeamCell label={g.home_team_label} record={g.home_record} row={branding.get(g.home_team_key)} />
        </span>
        <small className="mu-venue">
          {[g.stadium_name ?? g.venue, g.roof, g.surface].filter(Boolean).join(' · ')}
        </small>
      </span>

      {g.is_completed ? (
        <>
          <span className="n">
            <span className="v">
              {fmt(g.away_score)}–{fmt(g.home_score)}
            </span>
            <span className="s">Final{g.went_to_overtime ? ' · OT' : ''}</span>
          </span>
          <span className="n">
            <span className="v">{g.home_score !== null && g.away_score !== null ? g.home_score + g.away_score : '—'}</span>
            <span className="s">{g.total_result ? `${fmt(g.total_line, 1)} ${g.total_result}` : 'points'}</span>
          </span>
          <span className="n">
            <span className="v">{g.home_spread_result ? `${g.home_team_label} ${g.home_spread_result}` : '—'}</span>
            <span className="s">{g.home_spread_result ? `closed ${spreadText(g.home_spread)}` : 'no line'}</span>
          </span>
        </>
      ) : hasLine ? (
        <>
          <span className="n">
            <span className="v">{spreadLabel ?? '—'}</span>
            <span className="s">{short}</span>
          </span>
          <span className="n">
            <span className="v">{fmt(g.total_line, 1)}</span>
          </span>
          <span className="n">
            <span className="v">
              {mlFav !== null ? `${mlFavHome ? g.home_team_label : g.away_team_label} ${odds(mlFav)}` : '—'}
            </span>
            <span className="s">
              {mlOther !== null ? `${mlFavHome ? g.away_team_label : g.home_team_label} ${odds(mlOther)}` : ''}
            </span>
          </span>
        </>
      ) : (
        <>
          <span className="n pending">
            <span className="v">no line yet</span>
            <span className="s">
              {g.vendors_available.length ? `at ${g.vendors_available.map(bookShort).join(', ')}` : 'vendor-NULL'}
            </span>
          </span>
          <span className="n pending">
            <span className="v">—</span>
          </span>
          <span className="n pending">
            <span className="v">—</span>
          </span>
        </>
      )}

      {!g.is_weather_relevant ? (
        <span className="n wxc">
          <span className="v indoors">indoors</span>
          <span className="s">{[g.roof, g.surface].filter(Boolean).join(' · ')}</span>
        </span>
      ) : g.kickoff_temp_f !== null || g.wind_mph !== null ? (
        <span className={`n wxc${(g.wind_mph ?? 0) >= WIND_FLAG ? ' warn' : ''}`}>
          <span className="v">
            {fmt(g.kickoff_temp_f)}°F<i>·</i>
            <em>{fmt(g.wind_mph)} mph</em>
          </span>
          <span className="s">{(g.precip_in ?? 0) > 0 ? `${fmt(g.precip_in, 2)} in precip` : 'no precip'}</span>
        </span>
      ) : (
        <span className="n wxc pending">
          <span className="v">—</span>
          <span className="s">forecast inside the week</span>
        </span>
      )}

      <span className="n">
        <span className="v official">{g.referee ?? '—'}</span>
        <span className="s">Referee</span>
      </span>

      <AvailabilityCell g={g} />

      <span className="flc">
        {flags.map((f) =>
          f.cls === 'badge' ? (
            <span key={f.text} className="badge acc">
              {f.text}
            </span>
          ) : (
            <span key={f.text} className={`flag ${f.cls}`}>
              {f.text}
            </span>
          ),
        )}
      </span>
    </Link>
  )
}
