import { Link, useSearchParams } from 'react-router-dom'
import { fetchMarkets } from '../../api/sports/client.ts'
import type { LineRow, MarketsPayload } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import TeamLogo from '../../components/sports/TeamLogo.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBranding } from '../../hooks/useBranding.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, odds, signed, spreadText, tone } from '../../lib/format.ts'
import { useView } from '../../state/view.tsx'
import { WeekPicker } from './Slate.tsx'

export default function Markets() {
  return (
    <CapabilityGate cap="line_history">
      <MarketsBoard />
    </CapabilityGate>
  )
}

/** A game's path at one book: its snapshots in order, and the open and close. */
export interface GamePath {
  game_key: string
  rows: LineRow[]
  open: LineRow
  close: LineRow
}

export function groupByGame(rows: LineRow[]): GamePath[] {
  const by = new Map<string, LineRow[]>()
  for (const r of rows) {
    const list = by.get(r.game_key) ?? []
    list.push(r)
    by.set(r.game_key, list)
  }
  return [...by.entries()].map(([game_key, list]) => {
    const sorted = [...list].sort((a, b) => a.snapshot_number - b.snapshot_number)
    return { game_key, rows: sorted, open: sorted[0]!, close: sorted[sorted.length - 1]! }
  })
}

/** SUN 8:20P from the kickoff datetime -- the card's slot text. */
export function slotText(iso: string): string {
  const d = new Date(iso)
  const day = d.toLocaleDateString('en-US', { weekday: 'short', timeZone: 'America/New_York' }).toUpperCase()
  const time = d
    .toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York' })
    .replace(' AM', 'A')
    .replace(' PM', 'P')
  return `${day} ${time}`
}

function MarketsBoard() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const branding = useBranding(sport)
  const [search, setSearch] = useSearchParams()
  const { view, setView } = useView()

  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : undefined
  const seasonType = search.get('season_type') ?? undefined
  const weekParam = search.get('week')
  const week = weekParam ? Number(weekParam) : undefined
  // the book follows the board's memory, so Markets opens on the book you read lines at
  const vendor = search.get('vendor') ?? view.vendor

  const res = useApi(
    (signal) => fetchMarkets(sport, { season, season_type: seasonType, week, vendor }, signal),
    [sport, season, seasonType, week, vendor],
  )

  const set = (patch: Record<string, string | undefined>) => {
    const next = new URLSearchParams(search)
    for (const [k, v] of Object.entries(patch)) {
      if (v === undefined || v === '') next.delete(k)
      else next.set(k, v)
    }
    setSearch(next, { replace: true })
  }

  const data = res.data
  const label = caps?.label ?? sport.toUpperCase()
  const paths = data ? groupByGame(data.rows).sort((a, b) => a.open.game_datetime_et.localeCompare(b.open.game_datetime_et)) : []

  return (
    <div className="page page-markets">
      <div className="page-head">
        <h1>Markets</h1>
        <p className="lede">
          {data
            ? `${data.season_type_name} week ${data.week}, ${label} ${data.season}, at ${data.vendor}. Every pregame snapshot where the line moved, from the first number to the close.`
            : res.error
              ? res.error
              : 'Loading the week...'}
        </p>
      </div>

      {data && <Kpis data={data} paths={paths} />}

      <div className="filters">
        {data && <WeekPicker data={data} onPick={set} />}
        {caps && caps.vendors.length > 0 && (
          <Chips
            label="Book"
            items={caps.vendors.map((v) => ({ id: v, label: v }))}
            active={data?.vendor ?? vendor ?? caps.default_vendor}
            onPick={(id) => {
              const v = id === caps.default_vendor ? undefined : id
              setView({ vendor: v })
              set({ vendor: v })
            }}
          />
        )}
        <span className="hint">Click a game for every book's path and the props.</span>
      </div>

      {res.error && !data && (
        <section className="tile">
          <header className="tile-head">
            <h2>Nothing to show</h2>
          </header>
          <p className="hint">{res.error}</p>
        </section>
      )}

      {data && paths.length === 0 && (
        <section className="tile">
          <p className="hint">{data.vendor} has not priced this week. Pick another book.</p>
        </section>
      )}

      {data && paths.length > 0 && (
        <div className="grid cols-markets">
          {paths.map((p) => (
            <MoveCard
              key={p.game_key}
              path={p}
              sport={sport}
              vendor={vendor}
              branding={branding}
              badge={biggestMove(paths)?.game_key === p.game_key ? biggestMove(paths)?.text ?? null : null}
            />
          ))}
        </div>
      )}

      <TileFrame title="How this board is built" className="note-tile" query={data?.query}>
        <p>
          Two selects on the line history mart: the season's weeks with a line at any book (the picker, and the
          week in progress when the URL names none), then the chosen week at the chosen book. The mart keeps a
          snapshot only where something moved, so a game with one row was priced once and never changed; the
          "since open" numbers are the mart's, measured from that book's first number.
        </p>
      </TileFrame>
    </div>
  )
}

function Kpis({ data, paths }: { data: MarketsPayload; paths: GamePath[] }) {
  // a game "moved" when a number changed since its opener; a snapshot can also
  // be an odds change with the number held, which the cards show but this does not count
  const spread = paths.filter((p) => p.close.home_spread_since_open)
  const bigSpread = spread.length ? spread.reduce((a, b) => (Math.abs(b.close.home_spread_since_open!) > Math.abs(a.close.home_spread_since_open!) ? b : a)) : null
  const total = paths.filter((p) => p.close.total_line_since_open)
  const bigTotal = total.length ? total.reduce((a, b) => (Math.abs(b.close.total_line_since_open!) > Math.abs(a.close.total_line_since_open!) ? b : a)) : null
  const snapshots = data.rows.length
  const moved = paths.filter((p) => p.close.home_spread_since_open || p.close.total_line_since_open).length
  return (
    <div className="kpis four">
      <div className="kpi">
        <span className="l">Games priced</span>
        <span className="v">{paths.length}</span>
        <span className="s">{moved ? `${moved} with a spread or total off the opener` : 'no spread or total has moved off its opener'}</span>
      </div>
      <div className="kpi">
        <span className="l">Snapshots</span>
        <span className="v">{snapshots}</span>
        <span className="s">rows where a number or a price changed, this week at {data.vendor}</span>
      </div>
      <div className="kpi">
        <span className="l">Biggest spread move</span>
        <span className="v">{bigSpread ? signed(bigSpread.close.home_spread_since_open, 1) : 'none'}</span>
        <span className="s">{bigSpread ? `${bigSpread.open.away_team_label} at ${bigSpread.open.home_team_label}, ${spreadText(bigSpread.open.home_spread)} to ${spreadText(bigSpread.close.home_spread)}` : 'every spread sits on its opener'}</span>
      </div>
      <div className="kpi">
        <span className="l">Biggest total move</span>
        <span className="v">{bigTotal ? signed(bigTotal.close.total_line_since_open, 1) : 'none'}</span>
        <span className="s">{bigTotal ? `${bigTotal.open.away_team_label} at ${bigTotal.open.home_team_label}, ${fmt(bigTotal.open.total_line, 1)} to ${fmt(bigTotal.close.total_line, 1)}` : 'every total sits on its opener'}</span>
      </div>
    </div>
  )
}

/** The week's largest spread-or-total move, for the accent badge. */
function biggestMove(paths: GamePath[]): { game_key: string; text: string } | null {
  let best: { game_key: string; text: string; size: number } | null = null
  for (const p of paths) {
    const s = Math.abs(p.close.home_spread_since_open ?? 0)
    const t = Math.abs(p.close.total_line_since_open ?? 0)
    const size = Math.max(s, t)
    if (size > 0 && (best === null || size > best.size)) {
      best = {
        game_key: p.game_key,
        size,
        text:
          t >= s
            ? `biggest move · total ${signed(p.close.total_line_since_open, 1)}`
            : `biggest move · spread ${signed(p.close.home_spread_since_open, 1)}`,
      }
    }
  }
  return best
}

function MoveCard({
  path,
  sport,
  vendor,
  branding,
  badge,
}: {
  path: GamePath
  sport: string
  vendor: string | undefined
  branding: ReturnType<typeof useBranding>
  badge: string | null
}) {
  const o = path.open
  const c = path.close
  const href = `/${sport}/markets/${path.game_key}${vendor ? `?vendor=${encodeURIComponent(vendor)}` : ''}`
  return (
    <Link className="tile move-card" to={href} data-tilt="">
      <header className="tile-head">
        <span className="card-title">
          <TeamLogo teamKey={o.away_team_key} label={null} branding={branding} size="sm" />
          <h2>
            {o.away_team_label} @ {o.home_team_label}
          </h2>
          <TeamLogo teamKey={o.home_team_key} label={null} branding={branding} size="sm" />
        </span>
        <span className="card-meta">
          <span className="meta">{slotText(o.game_datetime_et)}</span>
          {badge && <span className="badge acc">{badge}</span>}
        </span>
      </header>
      <div className="move-grid">
        <div className="move">
          <span className="l">Spread</span>
          <span className="v">
            {o.home_team_label} {spreadText(o.home_spread)} <i>→</i> {spreadText(c.home_spread)}
          </span>
          <span className={`d ${tone(c.home_spread_since_open)}`}>{c.home_spread_since_open ? signed(c.home_spread_since_open, 1) : 'no move'}</span>
        </div>
        <div className="move">
          <span className="l">Total</span>
          <span className="v">
            {fmt(o.total_line, 1)} <i>→</i> {fmt(c.total_line, 1)}
          </span>
          <span className={`d ${tone(c.total_line_since_open)}`}>{c.total_line_since_open ? signed(c.total_line_since_open, 1) : 'no move'}</span>
        </div>
        <div className="move">
          <span className="l">Home ML</span>
          <span className="v">
            {odds(o.home_moneyline_odds)} <i>→</i> {odds(c.home_moneyline_odds)}
          </span>
          <span className="d">
            {c.home_moneyline_odds_change ? `${signed(c.home_moneyline_odds_change, 0)} last move` : 'no move'}
          </span>
        </div>
      </div>
      <Sparkline rows={path.rows} />
      <span className="spark-cap">
        spread path · {path.rows.length} snapshot{path.rows.length === 1 ? '' : 's'}
        {c.is_closing ? ' · closed' : ''}
      </span>
    </Link>
  )
}

/** The home spread over the snapshots, as a small step line. */
function Sparkline({ rows }: { rows: LineRow[] }) {
  const vals = rows.map((r) => r.home_spread ?? 0)
  if (vals.length < 2) return <div className="spark none">priced once, no movement yet</div>
  const W = 240
  const H = 36
  const min = Math.min(...vals)
  const max = Math.max(...vals)
  const span = max - min || 1
  const x = (i: number) => 4 + (i * (W - 8)) / (vals.length - 1)
  const y = (v: number) => H - 4 - ((v - min) / span) * (H - 8)
  const d = vals.map((v, i) => `${i === 0 ? 'M' : 'L'} ${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(' ')
  return (
    <svg className="spark" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Home spread over snapshots">
      <path d={d} />
      {vals.map((v, i) => (
        <circle key={i} cx={x(i)} cy={y(v)} r={2} />
      ))}
    </svg>
  )
}
