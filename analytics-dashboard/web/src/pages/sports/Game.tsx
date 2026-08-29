import { Link, useParams, useSearchParams } from 'react-router-dom'
import { fetchGame } from '../../api/sports/client.ts'
import type { GamePayload, PropRow, SlateRow } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import GameTabs from '../../components/sports/GameTabs.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBack } from '../../hooks/useBack.ts'
import { usePins, type Pin } from '../../hooks/usePins.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, odds, ordinal, pct, signed, spreadText, titleCase, tone } from '../../lib/format.ts'
import { PRECIP_FLAG, SPREAD_MOVE_FLAG, WIND_PASSING } from '../../lib/thresholds.ts'
import { boardPath, useView } from '../../state/view.tsx'

/** Stat families group prop types into one chip row. A family shows only when
    the selected book has rows in it; unknown prop types fall into "Other". */
interface Family {
  id: string
  label: string
  match: (propType: string) => boolean
}
const FAMILIES: Family[] = [
  { id: 'yards', label: 'Yards', match: (t) => t.endsWith('_yards') },
  { id: 'volume', label: 'Receptions / TD passes', match: (t) => t === 'receptions' || t === 'passing_tds' },
  { id: 'td', label: 'Touchdowns', match: (t) => t === 'anytime_td' || t === 'first_td' },
  { id: 'partial', label: 'Partial-game TDs', match: (t) => /_(1h|2h|1q|2q|3q|4q)$/.test(t) },
  { id: 'other', label: 'Other', match: () => true },
]
const POSITION_ORDER = ['QB', 'RB', 'WR', 'TE', 'K']

export default function Game() {
  return (
    <CapabilityGate cap="schedule">
      <GameBoard />
    </CapabilityGate>
  )
}

function GameBoard() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const { gameKey = '' } = useParams<{ gameKey: string }>()
  const [search, setSearch] = useSearchParams()
  const vendorParam = search.get('vendor') ?? undefined
  const familyParam = search.get('family')

  const res = useApi((signal) => fetchGame(sport, gameKey, vendorParam, signal), [sport, gameKey, vendorParam])
  const pins = usePins(sport)
  const { view, setView } = useView()
  // the board this game belongs to: the remembered week (and book), else the
  // game's own week once it has loaded
  const board = boardPath(sport, view)
  const back = useBack(board)

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
      <div className="page page-game">
        <GameTabs sport={sport} gameKey={gameKey} matchup={res.error ? 'No such game' : '...'} tab="Prop board" boardHref={board} back={back} vendorParam={vendorParam} />
        <div className="page-head">
          <h1>{res.error ? 'No such game' : 'Loading...'}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a game from the <Link to={board}>board</Link>.
            </p>
          )}
        </div>
      </div>
    )
  }

  const g = data.game
  // the book: the URL's, else the line's, else the first with any prop
  const vendor = vendorParam ?? g.vendor ?? data.vendors[0] ?? null
  const rows = [...data.away, ...data.home].filter((p) => p.vendor === vendor)
  const families = FAMILIES.filter((f) => rows.some((p) => familyOf(p.prop_type) === f.id))
  const family = families.find((f) => f.id === familyParam)?.id ?? families[0]?.id ?? null
  const shown = rows.filter((p) => familyOf(p.prop_type) === family)
  const hasLine = g.vendor !== null && g.home_spread !== null
  const notes = matchupNotes(g, rows)
  // the board for this game's week: the remembered view when it is the same
  // week, else the game's own week so a deep link still returns somewhere sane
  const sameWeek = view.week === g.week && (view.season_type ?? g.season_type_name) === g.season_type_name
  const slateHref = sameWeek
    ? board
    : boardPath(sport, { ...view, season: g.season, season_type: g.season_type_name, week: g.week })

  return (
    <div className="page page-game">
      <GameTabs
        sport={sport}
        gameKey={gameKey}
        matchup={`${g.away_team_label} @ ${g.home_team_label}`}
        tab="Prop board"
        boardHref={slateHref}
        back={back}
        vendorParam={vendorParam}
      />

      <div className="game-head" data-tilt="">
        <div className="matchup">
          <span className="kick">
            {g.kickoff_slot_et} ET · {g.season_type_name.toLowerCase()} week {g.week}
            {g.is_completed ? ' · final' : ''}
          </span>
          <h1>
            {g.away_team_name} <span className="at">at</span> {g.home_team_name}
          </h1>
          <p className="lede">
            {[g.stadium_name ?? g.venue, g.roof, weatherLine(g)].filter(Boolean).join(' · ')}
          </p>
        </div>
        {g.is_completed ? (
          <div className="line-strip">
            <Stat v={`${g.away_team_label} ${fmt(g.away_score)}`} l="Away" />
            <Stat v={`${g.home_team_label} ${fmt(g.home_score)}`} l="Home" />
            {hasLine && <Stat v={`${g.home_team_label} ${spreadText(g.home_spread)}`} l={`Closing spread, ${g.home_spread_result ?? ''}`} />}
            {hasLine && <Stat v={fmt(g.total_line, 1)} l={`Total, ${g.total_result ?? ''}`} />}
          </div>
        ) : hasLine ? (
          <div className="line-strip">
            <Stat v={`${g.home_team_label} ${spreadText(g.home_spread)}`} l={`Spread, ${g.vendor}`} />
            <Stat v={fmt(g.total_line, 1)} l="Total" />
            <Stat
              v={`${fmt(g.implied_away_team_total, 1)} / ${fmt(g.implied_home_team_total, 1)}`}
              l={`Implied ${g.away_team_label} / ${g.home_team_label}`}
            />
            <Stat
              v={g.home_spread_movement === null ? 'open' : signed(g.home_spread_movement, 1)}
              l="Move since open"
              cls={tone(g.home_spread_movement)}
            />
          </div>
        ) : (
          <div className="line-strip">
            <Stat v="No line" l={vendor ? `at ${vendor}` : 'no book'} />
          </div>
        )}
      </div>

      <div className="filters">
        {data.vendors.length > 0 && (
          <Chips
            label="Book"
            items={data.vendors.map((v) => ({ id: v, label: v }))}
            active={vendor}
            onPick={(id) => {
              const vendor = id === caps?.default_vendor ? undefined : id
              set({ vendor, family: undefined })
              setView({ vendor }) // the board follows the book chosen here
            }}
          />
        )}
        {families.length > 1 && (
          <Chips label="Stat family" items={families} active={family} onPick={(id) => set({ family: id })} />
        )}
        <span className="hint">
          Avg is the trailing window (up to ten games). Proj is Sleeper's number with its lean vs the
          line; when the board has projections, the leans sort it. Gap is avg minus the line. Rank is
          the opponent's yards allowed to that position, 1 = allows the most; * marks a prior-season rate.
        </span>
      </div>

      <div className="grid cols-game">
        <TeamColumn side="away" g={g} rows={shown.filter((p) => !p.is_home)} pins={pins} vendor={vendor} />
        <TeamColumn side="home" g={g} rows={shown.filter((p) => p.is_home)} pins={pins} vendor={vendor} />
        <div className="rail">
          <TileFrame title="Pinned plays" meta={String(pins.pins.length)}>
            {pins.pins.length ? (
              <ul className="pins">
                {pins.pins.map((p) => (
                  <li key={p.key}>
                    <b>{p.player_name}</b>
                    <button type="button" className="unpin" onClick={() => pins.remove(p.key)} title="Remove">
                      Remove
                    </button>
                    <small>
                      {p.team_label} · {p.prop_label} {p.line_value === null ? '' : fmt(p.line_value, 1)} · {p.vendor}
                    </small>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="hint">Pin a row to build a board for this slate. Pins stay in this browser.</p>
            )}
          </TileFrame>
          <TileFrame
            title="Matchup notes"
            meta="from the data"
            caption="Generated from yards allowed by position, the forecast, line movement and the news feed. No recommendation is made."
          >
            {notes.length ? (
              <ul className="notes">
                {notes.map((n) => (
                  <li key={n}>{n}</li>
                ))}
              </ul>
            ) : (
              <p className="hint">Nothing stands out in the columns yet.</p>
            )}
          </TileFrame>
        </div>
      </div>

      <TileFrame title="Behind the board" className="note-tile" query={data.query}>
        <p>
          Two selects. The game's slate rows give the line at the chosen book; the prop board mart gives
          one row per player, prop and book with the trailing window, the last three, the hit rate over
          this line, the gap, and the opponent's yards allowed to the position with its rank. The page
          only filters by book and stat family.
        </p>
      </TileFrame>
    </div>
  )
}

function Stat({ v, l, cls }: { v: string; l: string; cls?: string }) {
  return (
    <div className={`stat ${cls ?? ''}`}>
      <span className="v">{v}</span>
      <span className="l">{l}</span>
    </div>
  )
}

function weatherLine(g: SlateRow): string {
  if (g.kickoff_temp_f === null && g.wind_mph === null && g.precip_in === null) {
    return g.is_weather_relevant ? 'forecast arrives inside the week' : ''
  }
  return `${fmt(g.kickoff_temp_f)}F, wind ${fmt(g.wind_mph)} mph, precip ${fmt(g.precip_in, 2)} in`
}

function familyOf(propType: string): string {
  return FAMILIES.find((f) => f.match(propType))?.id ?? 'other'
}

function propLabel(p: PropRow): string {
  return p.stat_label ?? titleCase(p.prop_type)
}

function positionRank(p: PropRow): number {
  const i = POSITION_ORDER.indexOf(p.position ?? '')
  return i === -1 ? POSITION_ORDER.length : i
}

function TeamColumn({
  side,
  g,
  rows,
  pins,
  vendor,
}: {
  side: 'away' | 'home'
  g: SlateRow
  rows: PropRow[]
  pins: ReturnType<typeof usePins>
  vendor: string | null
}) {
  const name = side === 'home' ? g.home_team_name : g.away_team_name
  const label = side === 'home' ? g.home_team_label : g.away_team_label
  const implied = side === 'home' ? g.implied_home_team_total : g.implied_away_team_total
  // with projections on the board the leans lead (over leans first, under
  // leans last — the wireframe's Δ ordering); without them, position order
  const anyProjection = rows.some((p) => p.has_projection)
  const sorted = [...rows].sort((a, b) => {
    if (anyProjection && (a.projection_vs_line !== null || b.projection_vs_line !== null)) {
      if (a.projection_vs_line === null) return 1
      if (b.projection_vs_line === null) return -1
      if (a.projection_vs_line !== b.projection_vs_line) return b.projection_vs_line - a.projection_vs_line
    }
    return (
      positionRank(a) - positionRank(b) ||
      a.player_name.localeCompare(b.player_name) ||
      a.prop_type.localeCompare(b.prop_type)
    )
  })
  return (
    <TileFrame
      title={name}
      className={`team-col ${side}`}
      meta={implied !== null ? `implied ${fmt(implied, 1)}` : side}
    >
      {sorted.length === 0 ? (
        <p className="hint">No {vendor ?? ''} props in this family for {label}.</p>
      ) : (
        <div className="prows">
          {sorted.map((p) => (
            <PropLine key={p.app_game_prop_board_key} p={p} pins={pins} sideLabel={label} />
          ))}
        </div>
      )}
    </TileFrame>
  )
}

function PropLine({ p, pins, sideLabel }: { p: PropRow; pins: ReturnType<typeof usePins>; sideLabel: string }) {
  const key = p.app_game_prop_board_key
  const pinned = pins.has(key)
  const price = p.market_type === 'milestone' ? p.market_odds : p.over_odds
  const rank = p.opponent_allowed_rank
  const ranked = p.opponent_allowed_teams_ranked ?? 32
  const rankTone = rank === null ? '' : rank <= 8 ? 'pos' : rank >= ranked - 7 ? 'neg' : ''
  // the column's team, not the mart's team_label: that label can be the player's
  // previous team until a box score with the new one lands
  const moved = p.team_label !== null && p.team_label !== sideLabel
  const pin: Pin = {
    key,
    game_key: p.game_key,
    player_name: p.player_name,
    team_label: sideLabel,
    prop_label: propLabel(p),
    line_value: p.line_value,
    vendor: p.vendor,
  }
  return (
    <div className="prow" data-pos={p.position ?? ''}>
      <div className="pid">
        <b>{p.player_name}</b>
        <small title={moved ? `form from ${p.team_label}` : undefined}>
          {p.position ?? ''} · {propLabel(p)}
          {p.market_type === 'milestone' ? ' (yes)' : ''}
          {moved ? ` · ex-${p.team_label}` : ''}
        </small>
        {p.usage_trailing3_games > 0 && (p.target_share_trailing3 !== null || p.snap_pct_trailing3 !== null) && (
          <small className="usage" title={`trailing ${p.usage_trailing3_games} games`}>
            {[
              p.target_share_trailing3 !== null ? `tgt ${pct(p.target_share_trailing3)}` : null,
              p.snap_pct_trailing3 !== null ? `snap ${pct(p.snap_pct_trailing3)}` : null,
            ]
              .filter(Boolean)
              .join(' · ')}
          </small>
        )}
        {p.news_context && <span className="flag news">{p.news_context}</span>}
      </div>
      <div className="pnum" title="Per-game average over the trailing window">
        <span className="v">{p.trailing_games ? fmt(p.trailing_avg, 1) : '–'}</span>
        <span className="l">{p.trailing_games ? `Avg (${p.trailing_games})` : 'No games'}</span>
      </div>
      <div className="pnum last3">
        <span className="v">{p.stat_last3?.length ? p.stat_last3.map((x) => fmt(x, 0)).join(' · ') : '–'}</span>
        <span className="l">Last 3</span>
      </div>
      <div className="pnum" title={`${p.vendor} line and price`}>
        <span className="v">
          {p.line_value === null ? '–' : fmt(p.line_value, 1)}
          {price !== null && <small> {odds(price)}</small>}
        </span>
        <span className="l">Line</span>
      </div>
      <div className={`pnum ${tone(p.projection_vs_line)}`} title="Sleeper projection, and its lean vs the line">
        <span className="v">
          {p.projection_value === null ? '–' : fmt(p.projection_value, 1)}
          {p.projection_vs_line !== null && <small> {signed(p.projection_vs_line, 1)}</small>}
        </span>
        <span className="l">{p.projection_vs_line === null ? 'Proj' : (p.projection_vs_line ?? 0) >= 0 ? 'over lean' : 'under lean'}</span>
      </div>
      <div className={`pnum ${tone(p.gap_to_line)}`} title="Trailing average minus the line">
        <span className="v">{p.gap_to_line === null ? '–' : signed(p.gap_to_line, 1)}</span>
        <span className="l">Gap</span>
      </div>
      <div className="pnum" title="Games over this line in the trailing window">
        <span className="v">{p.trailing_games ? `${p.trailing_over_line ?? 0}/${p.trailing_games}` : '–'}</span>
        <span className="l">Over</span>
      </div>
      <div className={`pnum ${rankTone}`} title={`${p.opponent_label ?? 'Opponent'} ${titleCase(p.opponent_allowed_stat_key).toLowerCase()} allowed to ${p.position ?? 'the position'}, ${fmt(p.opponent_allowed_per_game, 1)} per game; 1 = allows the most`}>
        <span className="v">{rank === null ? '–' : `#${rank}`}</span>
        <span className="l">
          {p.opponent_label ?? 'opp'} v {p.position ?? 'pos'}
          {p.opponent_allowed_season && p.opponent_allowed_season !== p.season ? '*' : ''}
        </span>
      </div>
      {p.is_completed ? (
        <span className={`pin ${p.outcome === 'over' || p.outcome === 'hit' ? 'on' : ''}`} title="Result">
          {p.actual_value === null ? 'no box' : `${fmt(p.actual_value, 0)} ${p.outcome ?? ''}`}
        </span>
      ) : (
        <button type="button" className={`pin ${pinned ? 'on' : ''}`} onClick={() => pins.toggle(pin)} aria-pressed={pinned}>
          {pinned ? 'Pinned' : 'Pin'}
        </button>
      )}
    </div>
  )
}

/** Sentences from the columns: extreme opponent ranks per position, the
    forecast, the line move, and the news headlines on the board. */
function matchupNotes(g: SlateRow, rows: PropRow[]): string[] {
  const notes: string[] = []
  const seen = new Set<string>()
  for (const p of rows) {
    if (p.opponent_allowed_rank === null || !p.opponent_label || !p.position) continue
    const key = `${p.opponent_label}:${p.position}:${p.opponent_allowed_stat_key}`
    if (seen.has(key)) continue
    seen.add(key)
    const ranked = p.opponent_allowed_teams_ranked ?? 32
    const stat = titleCase(p.opponent_allowed_stat_key).toLowerCase()
    const per = fmt(p.opponent_allowed_per_game, 1)
    const team = p.is_home ? g.home_team_label : g.away_team_label
    const season = p.opponent_allowed_season && p.opponent_allowed_season !== p.season ? ` (${p.opponent_allowed_season} rate)` : ''
    if (p.opponent_allowed_rank <= 6) {
      notes.push(`${p.opponent_label} allows the ${ordinal(p.opponent_allowed_rank)}-most ${stat} to ${p.position}s (${per} per game)${season}, which favours ${team}'s ${p.position}s.`)
    } else if (p.opponent_allowed_rank >= ranked - 5) {
      notes.push(`${p.opponent_label} is ${ordinal(ranked + 1 - p.opponent_allowed_rank)}-stingiest against ${p.position}s in ${stat} (${per} per game)${season}, a fade for ${team}'s ${p.position}s.`)
    }
  }
  if (g.is_weather_relevant && (g.wind_mph ?? 0) >= WIND_PASSING) {
    notes.push(`Wind ${fmt(g.wind_mph)} mph at ${g.stadium_name ?? 'the stadium'}: passing volume props are flagged; the market usually shades totals down in this range.`)
  }
  if (g.is_weather_relevant && (g.precip_in ?? 0) >= PRECIP_FLAG) {
    notes.push(`Rain forecast (${fmt(g.precip_in, 2)} in): handling and kicking props carry extra variance.`)
  }
  if (g.home_spread_movement !== null && Math.abs(g.home_spread_movement) >= SPREAD_MOVE_FLAG) {
    const toward = g.home_spread_movement < 0 ? g.home_team_label : g.away_team_label
    notes.push(`The spread moved ${signed(g.home_spread_movement, 1)} toward ${toward} since open; player lines on that side often lag the game line.`)
  }
  const headlines = new Set<string>()
  for (const p of rows) {
    if (p.news_headline && headlines.size < 4 && !headlines.has(p.news_headline)) {
      headlines.add(p.news_headline)
      notes.push(`${p.player_name}: ${p.news_headline}`)
    }
  }
  return notes
}

export type { GamePayload }
