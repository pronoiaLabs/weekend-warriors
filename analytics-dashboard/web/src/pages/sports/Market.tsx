import { Link, useParams, useSearchParams } from 'react-router-dom'
import { fetchGameMarkets } from '../../api/sports/client.ts'
import type { LineRow, PropLineRow } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import Crumbs from '../../components/sports/Crumbs.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBack } from '../../hooks/useBack.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import GameTabs from '../../components/sports/GameTabs.tsx'
import Avatar from '../../components/sports/Avatar.tsx'
import { fmt, odds, signed, spreadText, titleCase, tone } from '../../lib/format.ts'
import { boardPath, useView, viewSearch } from '../../state/view.tsx'

type Metric = 'spread' | 'total' | 'homeml'

export default function Market({ family = false }: { family?: boolean }) {
  return (
    <CapabilityGate cap="line_history">
      <MarketPage family={family} />
    </CapabilityGate>
  )
}

function MarketPage({ family }: { family: boolean }) {
  const sport = useSportParam()
  const caps = useCapabilities()
  const { gameKey = '' } = useParams<{ gameKey: string }>()
  const [search, setSearch] = useSearchParams()
  const { view, setView } = useView()
  const vendorParam = search.get('vendor') ?? undefined
  const metricParam = search.get('metric')
  const metric: Metric = metricParam === 'total' ? 'total' : metricParam === 'homeml' ? 'homeml' : 'spread'

  const res = useApi((signal) => fetchGameMarkets(sport, gameKey, vendorParam, signal), [sport, gameKey, vendorParam])
  // as the game family's Lines tab the page belongs to the slate; standalone
  // (from the Markets board) it keeps its own home
  const boardHref = family ? boardPath(sport, view) : `/${sport}/markets${viewSearch(view)}`
  const back = useBack(boardHref)

  const set = (patch: Record<string, string | undefined>) => {
    const next = new URLSearchParams(search)
    for (const [k, v] of Object.entries(patch)) {
      if (v === undefined || v === '') next.delete(k)
      else next.set(k, v)
    }
    setSearch(next, { replace: true })
  }

  const data = res.data
  if (!data) {
    return (
      <div className="page page-market">
        {family ? (
          <GameTabs sport={sport} gameKey={gameKey} matchup={res.error ? 'No lines' : '...'} tab="Lines" boardHref={boardHref} back={back} vendorParam={vendorParam} />
        ) : (
          <Crumbs items={[{ label: 'Markets', to: boardHref }, { label: res.error ? 'No lines' : '...' }]} />
        )}
        <div className="page-head">
          <h1>{res.error ? 'No lines for this game' : 'Loading...'}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a game from the <Link to={boardHref}>{family ? 'slate' : 'markets board'}</Link>.
            </p>
          )}
        </div>
      </div>
    )
  }

  const g = data.game
  const byBook = new Map<string, LineRow[]>()
  for (const r of data.lines) byBook.set(r.vendor, [...(byBook.get(r.vendor) ?? []), r])
  const chosen = data.vendor && byBook.has(data.vendor) ? data.vendor : (data.vendors[0] ?? null)
  const chosenRows = chosen ? byBook.get(chosen)! : []
  const props = groupProps(data.props)
  const gameHref = `/${sport}/games/${g.game_key}${chosen ? `?vendor=${encodeURIComponent(chosen)}` : ''}`

  return (
    <div className="page page-market">
      {family ? (
        <GameTabs
          sport={sport}
          gameKey={gameKey}
          matchup={`${g.away_team_label} @ ${g.home_team_label}`}
          tab="Lines"
          boardHref={boardHref}
          back={back}
          vendorParam={vendorParam}
        />
      ) : (
        <div className="crumb-row">
          <Crumbs items={[{ label: 'Markets', to: boardHref }, { label: `${g.away_team_label} at ${g.home_team_label}` }]} />
          <button type="button" className="back" onClick={back}>
            <span aria-hidden="true">←</span> Back to markets
          </button>
        </div>
      )}

      <div className="game-head" data-tilt="">
        <div className="matchup">
          <span className="kick">
            {g.season_type_name.toLowerCase()} week {g.week} · {g.game_date}
            {g.is_completed ? ' · final' : ''}
          </span>
          <h1>
            {g.away_team_name} <span className="at">at</span> {g.home_team_name}
          </h1>
          <p className="lede">
            Priced at {data.vendors.length} book{data.vendors.length === 1 ? '' : 's'}: {data.vendors.join(', ')}.{' '}
            {family ? (
              <>Every point on a path is a snapshot where the number moved.</>
            ) : (
              <Link to={gameHref}>Open the game's prop board.</Link>
            )}
          </p>
        </div>
        <div className="line-strip">
          {chosenRows.length > 0 && <CloseStrip rows={chosenRows} home={g.home_team_label ?? ''} />}
        </div>
      </div>

      <div className="filters">
        {caps && caps.vendors.length > 0 && (
          <Chips
            label="Book"
            items={caps.vendors.map((v) => ({ id: v, label: v }))}
            active={data.vendor}
            onPick={(id) => {
              const v = id === caps.default_vendor ? undefined : id
              setView({ vendor: v })
              set({ vendor: v })
            }}
          />
        )}
        <Chips
          label="Chart"
          items={[
            { id: 'spread', label: `Spread (${g.home_team_label})` },
            { id: 'total', label: 'Total' },
            { id: 'homeml', label: 'Home ML' },
          ]}
          active={metric}
          onPick={(id) => set({ metric: id === 'spread' ? undefined : id })}
        />
      </div>

      <TileFrame
        title={
          metric === 'spread'
            ? `${g.home_team_label} spread, every book`
            : metric === 'total'
              ? 'Total, every book'
              : `${g.home_team_label} moneyline, every book`
        }
        meta="hours before kickoff"
        className="chart-tile"
        caption="One step line per book over the hours before kickoff; the highlighted path is the chosen book. A book with one point was priced once and never moved."
      >
        {chosenRows.length > 0 && <Summary rows={chosenRows} metric={metric} home={g.home_team_label ?? ''} />}
        <PathChart byBook={byBook} metric={metric} chosen={chosen} />
        <ul className="legend">
          {[...byBook.keys()].map((v) => (
            <li key={v} className={v === chosen ? 'on' : ''}>
              <i className={`sw ${v === chosen ? 'on' : ''}`} />
              {v} · {byBook.get(v)!.length}
            </li>
          ))}
        </ul>
      </TileFrame>

      <TileFrame title={`Snapshots at ${chosen ?? 'no book'}`} meta={`${chosenRows.length} rows`} className="table-tile">
        <SnapshotTable rows={chosenRows} home={g.home_team_label ?? ''} />
      </TileFrame>

      <TileFrame
        title={`Prop movement at ${data.vendor ?? 'no book'}`}
        meta={`${props.length} props`}
        className="table-tile"
        caption={
          props.length
            ? 'Open to close per prop, largest move first. The flagged rows are the tell worth surfacing: the line moved one way while the over price eased with it — the book changed the number and still drew money on that side.'
            : `${data.vendor} has no prop snapshots for this game.`
        }
      >
        <PropsTable
          props={props}
          sport={sport}
          book={data.vendor}
          playerSearch={`?season=${g.season}&season_type=${encodeURIComponent(g.season_type_name)}`}
        />
      </TileFrame>

      <TileFrame title="How this page is built" className="note-tile" query={data.query}>
        <p>
          Two selects: the line history for the game at every book, and the prop line history for the game at the
          chosen book (FanDuel re-snapshots every tick, so one game at that book is thousands of rows, which is why
          props are bound to one book). Both marts keep a snapshot only where a number changed, and carry the change
          from the previous snapshot and since the first.
        </p>
      </TileFrame>
    </div>
  )
}

function CloseStrip({ rows, home }: { rows: LineRow[]; home: string }) {
  const o = rows[0]!
  const c = rows[rows.length - 1]!
  return (
    <>
      <Stat v={`${home} ${spreadText(c.home_spread)}`} l={`Spread${c.is_closing ? ', closing' : ', latest'}`} />
      <Stat v={c.home_spread_since_open ? signed(c.home_spread_since_open, 1) : 'unchanged'} l={`Since open (${spreadText(o.home_spread)})`} cls={tone(c.home_spread_since_open)} />
      <Stat v={fmt(c.total_line, 1)} l="Total" />
      <Stat v={c.total_line_since_open ? signed(c.total_line_since_open, 1) : 'unchanged'} l={`Since open (${fmt(o.total_line, 1)})`} cls={tone(c.total_line_since_open)} />
      <Stat v={`${odds(c.away_moneyline_odds)} / ${odds(c.home_moneyline_odds)}`} l="Moneyline away / home" />
      <Stat v={String(rows.length)} l="Snapshots with a change" />
    </>
  )
}

/** The metric's story in one line above the chart: open, now, and the shape. */
function Summary({ rows, metric, home }: { rows: LineRow[]; metric: Metric; home: string }) {
  const o = rows[0]!
  const c = rows[rows.length - 1]!
  const pick = (r: LineRow) => (metric === 'spread' ? r.home_spread : metric === 'total' ? r.total_line : r.home_moneyline_odds)
  const show = (v: number | null) => (metric === 'spread' ? spreadText(v) : metric === 'total' ? fmt(v, 1) : odds(v))
  const ov = pick(o)
  const cv = pick(c)
  const moved = ov !== null && cv !== null && ov !== cv
  return (
    <p className="chart-summary">
      <b>
        {metric === 'total' ? '' : `${home} `}
        {show(ov)} open → {show(cv)} now
      </b>{' '}
      · {moved ? `${rows.length} snapshots where a number changed` : 'held its opener'}
    </p>
  )
}

function Stat({ v, l, cls }: { v: string; l: string; cls?: string }) {
  return (
    <div className={`stat ${cls ?? ''}`}>
      <span className="v">{v || '—'}</span>
      <span className="l">{l}</span>
    </div>
  )
}

/** Step lines per book: x is hours before kickoff (right edge = kickoff), y the
    metric. Every book shares the axes so the spread between them is visible. */
function PathChart({ byBook, metric, chosen }: { byBook: Map<string, LineRow[]>; metric: Metric; chosen: string | null }) {
  const W = 640
  const H = 200
  const padL = 34
  const padR = 10
  const padY = 14
  const pick = (r: LineRow) => (metric === 'spread' ? r.home_spread : metric === 'total' ? r.total_line : r.home_moneyline_odds)
  const all = [...byBook.values()].flat()
  const ys = all.map(pick).filter((v): v is number => v !== null)
  const hs = all.map((r) => r.hours_before_kickoff ?? 0)
  if (ys.length === 0) return <p className="hint">No line on this metric.</p>
  const padUnits = metric === 'homeml' ? 5 : 0.5
  const yMin = Math.min(...ys) - padUnits
  const yMax = Math.max(...ys) + padUnits
  const hMax = Math.max(1, ...hs)
  const x = (h: number) => padL + ((hMax - h) / hMax) * (W - padL - padR)
  const y = (v: number) => padY + ((yMax - v) / (yMax - yMin || 1)) * (H - padY * 2)
  const ticks = [yMin + padUnits, (yMin + yMax) / 2, yMax - padUnits]
  return (
    <svg className="path-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Line path by book">
      {ticks.map((t) => (
        <g key={t}>
          <line x1={padL} x2={W - padR} y1={y(t)} y2={y(t)} className="grid" />
          <text x={padL - 6} y={y(t) + 3} className="lbl" textAnchor="end">
            {metric === 'spread' ? spreadText(Math.round(t * 2) / 2) : metric === 'total' ? fmt(t, 1) : odds(Math.round(t))}
          </text>
        </g>
      ))}
      <text x={W - padR} y={H - 2} className="lbl" textAnchor="end">
        kickoff
      </text>
      <text x={padL} y={H - 2} className="lbl">
        {fmt(hMax, 0)}h before
      </text>
      {[...byBook.entries()].map(([vendor, rows]) => {
        const pts = rows
          .filter((r) => pick(r) !== null)
          .sort((a, b) => a.snapshot_number - b.snapshot_number)
          .map((r) => ({ x: x(r.hours_before_kickoff ?? 0), y: y(pick(r)!) }))
        if (pts.length === 0) return null
        // a step path: hold the value until the next snapshot, then end at kickoff
        let d = `M ${pts[0]!.x.toFixed(1)} ${pts[0]!.y.toFixed(1)}`
        for (let i = 1; i < pts.length; i++) d += ` L ${pts[i]!.x.toFixed(1)} ${pts[i - 1]!.y.toFixed(1)} L ${pts[i]!.x.toFixed(1)} ${pts[i]!.y.toFixed(1)}`
        d += ` L ${(W - padR).toFixed(1)} ${pts[pts.length - 1]!.y.toFixed(1)}`
        const on = vendor === chosen
        return (
          <g key={vendor} className={`book ${on ? 'on' : ''}`}>
            <title>{vendor}</title>
            <path d={d} />
            {pts.map((p, i) => (
              <circle key={i} cx={p.x} cy={p.y} r={on ? 3 : 2} />
            ))}
          </g>
        )
      })}
    </svg>
  )
}

function SnapshotTable({ rows, home }: { rows: LineRow[]; home: string }) {
  if (rows.length === 0) return <p className="hint">No snapshots at this book.</p>
  return (
    <div className="trows" style={{ '--cols': '32px minmax(150px, 1.4fr) 80px repeat(8, minmax(56px, .8fr))' } as React.CSSProperties}>
      <div className="trow head">
        <span className="n">#</span>
        <span>Observed (ET)</span>
        <span className="n">Hours out</span>
        <span className="n">{home} spread</span>
        <span className="n">Move</span>
        <span className="n">Odds</span>
        <span className="n">Total</span>
        <span className="n">Move</span>
        <span className="n">O / U</span>
        <span className="n">ML away</span>
        <span className="n">ML home</span>
      </div>
      {rows.map((r) => (
        <div key={r.app_line_history_key} className="trow">
          <span className="n rk">{r.snapshot_number}</span>
          <span className="tm">
            <b>{r.snapshot_observed_at.replace('T', ' ').slice(0, 16)}</b>
            <small>{r.is_opening ? 'opening' : r.is_closing ? 'closing' : ''}</small>
          </span>
          <span className="n">{fmt(r.hours_before_kickoff, 1)}</span>
          <span className="n">{spreadText(r.home_spread)}</span>
          <span className={`n ${tone(r.home_spread_change)}`}>{r.home_spread_change ? signed(r.home_spread_change, 1) : ''}</span>
          <span className="n">
            {odds(r.home_spread_odds)}
          </span>
          <span className="n">{fmt(r.total_line, 1)}</span>
          <span className={`n ${tone(r.total_line_change)}`}>{r.total_line_change ? signed(r.total_line_change, 1) : ''}</span>
          <span className="n">
            {odds(r.over_odds)} / {odds(r.under_odds)}
          </span>
          <span className="n">{odds(r.away_moneyline_odds)}</span>
          <span className="n">{odds(r.home_moneyline_odds)}</span>
        </div>
      ))}
    </div>
  )
}

interface PropPath {
  key: string
  player_key: string
  player_name: string
  position: string | null
  prop: string
  market_type: string
  open: PropLineRow
  close: PropLineRow
  rows: PropLineRow[]
  snapshots: number
  /** the tell: the line moved one way while the over's price eased with it --
      the book changed the number and still drew money on the same side */
  steam: boolean
}

function groupProps(rows: PropLineRow[]): PropPath[] {
  const by = new Map<string, PropLineRow[]>()
  for (const r of rows) by.set(r.game_player_vendor_prop_key, [...(by.get(r.game_player_vendor_prop_key) ?? []), r])
  return [...by.entries()]
    .map(([key, list]) => {
      const sorted = [...list].sort((a, b) => a.snapshot_number - b.snapshot_number)
      const o = sorted[0]!
      const c = sorted[sorted.length - 1]!
      const lineDelta = c.line_value_since_open ?? 0
      const oddsDelta = o.over_odds !== null && c.over_odds !== null ? c.over_odds - o.over_odds : 0
      const steam = Math.abs(lineDelta) >= 1 && Math.abs(oddsDelta) >= 3 && Math.sign(lineDelta) === Math.sign(oddsDelta)
      return {
        key,
        player_key: o.player_key,
        player_name: o.player_name ?? 'Unknown',
        position: o.position,
        prop: o.stat_label ?? titleCase(o.prop_type),
        market_type: o.market_type,
        open: o,
        close: c,
        rows: sorted,
        snapshots: sorted.length,
        steam,
      }
    })
    .sort((a, b) => Math.abs(b.close.line_value_since_open ?? 0) - Math.abs(a.close.line_value_since_open ?? 0) || b.snapshots - a.snapshots || a.player_name.localeCompare(b.player_name))
}

function PropSpark({ rows }: { rows: PropLineRow[] }) {
  const vals = rows.map((r) => r.line_value).filter((v): v is number => v !== null)
  if (vals.length < 2) return <span className="spark none">—</span>
  const W = 96
  const H = 24
  const min = Math.min(...vals)
  const max = Math.max(...vals)
  const span = max - min || 1
  const x = (i: number) => 3 + (i * (W - 6)) / (vals.length - 1)
  const y = (v: number) => H - 3 - ((v - min) / span) * (H - 6)
  const d = vals.map((v, i) => `${i === 0 ? 'M' : 'L'} ${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(' ')
  return (
    <svg className="spark prop-spark" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Line over snapshots">
      <path d={d} />
      <circle cx={x(vals.length - 1)} cy={y(vals[vals.length - 1]!)} r={2} />
    </svg>
  )
}

function PropsTable({ props, sport, playerSearch, book }: { props: PropPath[]; sport: string; playerSearch: string; book: string | null }) {
  if (props.length === 0) return null
  const short = book ? (BOOK_SHORT[book] ?? book.toUpperCase().slice(0, 3)) : '—'
  return (
    <div className="trows proplines" style={{ '--cols': 'minmax(170px, 1.7fr) minmax(104px, 1.1fr) repeat(3, minmax(58px, .7fr)) minmax(96px, 1fr) minmax(50px, .6fr) 96px' } as React.CSSProperties}>
      <div className="trow head">
        <span>Player</span>
        <span>Prop</span>
        <span className="n">Open</span>
        <span className="n sorted">Now</span>
        <span className="n">Δ line</span>
        <span className="n">Over price</span>
        <span className="n">Book</span>
        <span className="n">Path</span>
      </div>
      {props.map((p) => (
        <Link key={p.key} className="trow" to={`/${sport}/players/${p.player_key}${playerSearch}`}>
          <span className="pcell">
            <Avatar name={p.player_name} size="sm" />
            <span className="who">
              <b>{p.player_name}</b>
              <small>{p.position ?? '—'}</small>
            </span>
            {p.steam && <span className="badge warn prop-flag">steam vs buyback</span>}
          </span>
          <span className="tm">
            <b>{p.prop}</b>
            <small>{p.market_type === 'milestone' ? 'milestone' : 'over / under'}</small>
          </span>
          <span className="n">{p.open.line_value === null ? '' : fmt(p.open.line_value, 1)}</span>
          <span className="n sorted">{p.close.line_value === null ? '' : fmt(p.close.line_value, 1)}</span>
          <span className={`n ${tone(p.close.line_value_since_open)}`}>{p.close.line_value_since_open ? signed(p.close.line_value_since_open, 1) : '–'}</span>
          <span className={`n ${p.steam ? 'pos' : ''}`}>
            {p.market_type === 'milestone'
              ? odds(p.close.market_odds)
              : `${odds(p.open.over_odds)} → ${odds(p.close.over_odds)}`}
          </span>
          <span className="n">{short}</span>
          <span className="n">
            <PropSpark rows={p.rows} />
          </span>
        </Link>
      ))}
    </div>
  )
}

const BOOK_SHORT: Record<string, string> = {
  draftkings: 'DK',
  fanduel: 'FD',
  betmgm: 'MGM',
  caesars: 'CZR',
  betrivers: 'BR',
  kalshi: 'KAL',
  polymarket: 'PM',
}
