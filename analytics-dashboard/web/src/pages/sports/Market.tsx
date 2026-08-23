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
import { fmt, odds, signed, spreadText, titleCase, tone } from '../../lib/format.ts'
import { useView, viewSearch } from '../../state/view.tsx'

export default function Market() {
  return (
    <CapabilityGate cap="line_history">
      <MarketPage />
    </CapabilityGate>
  )
}

function MarketPage() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const { gameKey = '' } = useParams<{ gameKey: string }>()
  const [search, setSearch] = useSearchParams()
  const { view, setView } = useView()
  const vendorParam = search.get('vendor') ?? undefined
  const metric = search.get('metric') === 'total' ? 'total' : 'spread'

  const res = useApi((signal) => fetchGameMarkets(sport, gameKey, vendorParam, signal), [sport, gameKey, vendorParam])
  const boardHref = `/${sport}/markets${viewSearch(view)}`
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
        <Crumbs items={[{ label: 'Markets', to: boardHref }, { label: res.error ? 'No lines' : '...' }]} />
        <div className="page-head">
          <h1>{res.error ? 'No lines for this game' : 'Loading...'}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a game from the <Link to={boardHref}>markets board</Link>.
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
      <div className="crumb-row">
        <Crumbs items={[{ label: 'Markets', to: boardHref }, { label: `${g.away_team_label} at ${g.home_team_label}` }]} />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to markets
        </button>
      </div>

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
            Priced at {data.vendors.length} book{data.vendors.length === 1 ? '' : 's'}: {data.vendors.join(', ')}. <Link to={gameHref}>Open the game's prop board.</Link>
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
          ]}
          active={metric}
          onPick={(id) => set({ metric: id === 'spread' ? undefined : id })}
        />
      </div>

      <TileFrame
        title={metric === 'spread' ? `${g.home_team_label} spread, every book` : 'Total, every book'}
        meta="hours before kickoff"
        className="chart-tile"
        caption="One step line per book over the hours before kickoff; the highlighted path is the chosen book. A book with one point was priced once and never moved."
      >
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
        caption={props.length ? 'Open to close per prop, largest move first. Props the book priced once show no movement.' : `${data.vendor} has no prop snapshots for this game.`}
      >
        <PropsTable props={props} sport={sport} />
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
function PathChart({ byBook, metric, chosen }: { byBook: Map<string, LineRow[]>; metric: 'spread' | 'total'; chosen: string | null }) {
  const W = 640
  const H = 200
  const padL = 34
  const padR = 10
  const padY = 14
  const pick = (r: LineRow) => (metric === 'spread' ? r.home_spread : r.total_line)
  const all = [...byBook.values()].flat()
  const ys = all.map(pick).filter((v): v is number => v !== null)
  const hs = all.map((r) => r.hours_before_kickoff ?? 0)
  if (ys.length === 0) return <p className="hint">No line on this metric.</p>
  const yMin = Math.min(...ys) - 0.5
  const yMax = Math.max(...ys) + 0.5
  const hMax = Math.max(1, ...hs)
  const x = (h: number) => padL + ((hMax - h) / hMax) * (W - padL - padR)
  const y = (v: number) => padY + ((yMax - v) / (yMax - yMin || 1)) * (H - padY * 2)
  const ticks = [yMin + 0.5, (yMin + yMax) / 2, yMax - 0.5]
  return (
    <svg className="path-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Line path by book">
      {ticks.map((t) => (
        <g key={t}>
          <line x1={padL} x2={W - padR} y1={y(t)} y2={y(t)} className="grid" />
          <text x={padL - 6} y={y(t) + 3} className="lbl" textAnchor="end">
            {metric === 'spread' ? spreadText(Math.round(t * 2) / 2) : fmt(t, 1)}
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
  team: string
  prop: string
  market_type: string
  open: PropLineRow
  close: PropLineRow
  snapshots: number
}

function groupProps(rows: PropLineRow[]): PropPath[] {
  const by = new Map<string, PropLineRow[]>()
  for (const r of rows) by.set(r.game_player_vendor_prop_key, [...(by.get(r.game_player_vendor_prop_key) ?? []), r])
  return [...by.entries()]
    .map(([key, list]) => {
      const sorted = [...list].sort((a, b) => a.snapshot_number - b.snapshot_number)
      const o = sorted[0]!
      const c = sorted[sorted.length - 1]!
      return {
        key,
        player_key: o.player_key,
        player_name: o.player_name ?? 'Unknown',
        position: o.position,
        team: '',
        prop: o.stat_label ?? titleCase(o.prop_type),
        market_type: o.market_type,
        open: o,
        close: c,
        snapshots: sorted.length,
      }
    })
    .sort((a, b) => Math.abs(b.close.line_value_since_open ?? 0) - Math.abs(a.close.line_value_since_open ?? 0) || b.snapshots - a.snapshots || a.player_name.localeCompare(b.player_name))
}

function PropsTable({ props, sport }: { props: PropPath[]; sport: string }) {
  if (props.length === 0) return null
  return (
    <div className="trows" style={{ '--cols': 'minmax(150px, 1.6fr) minmax(120px, 1.2fr) repeat(5, minmax(60px, .8fr))' } as React.CSSProperties}>
      <div className="trow head">
        <span>Player</span>
        <span>Prop</span>
        <span className="n">Open</span>
        <span className="n">Latest</span>
        <span className="n">Since open</span>
        <span className="n">Odds</span>
        <span className="n">Snapshots</span>
      </div>
      {props.map((p) => (
        <Link key={p.key} className="trow" to={`/${sport}/players/${p.player_key}`}>
          <span className="tm">
            <b>{p.player_name}</b>
            <small>{p.position}</small>
          </span>
          <span className="tm">
            <b>{p.prop}</b>
            <small>{p.market_type === 'milestone' ? 'milestone' : 'over / under'}</small>
          </span>
          <span className="n">{p.open.line_value === null ? '' : fmt(p.open.line_value, 1)}</span>
          <span className="n">{p.close.line_value === null ? '' : fmt(p.close.line_value, 1)}</span>
          <span className={`n ${tone(p.close.line_value_since_open)}`}>{p.close.line_value_since_open ? signed(p.close.line_value_since_open, 1) : 'unchanged'}</span>
          <span className="n">{p.market_type === 'milestone' ? odds(p.close.market_odds) : `${odds(p.close.over_odds)} / ${odds(p.close.under_odds)}`}</span>
          <span className="n">{p.snapshots}</span>
        </Link>
      ))}
    </div>
  )
}
