import { Link, useParams, useSearchParams } from 'react-router-dom'
import { fetchGame } from '../../../api/sports/client.ts'
import type { AllowedRow, GamePayload, SlateRow, StatusRow } from '../../../api/sports/types.ts'
import CapabilityGate from '../../../components/sports/CapabilityGate.tsx'
import GameTabs from '../../../components/sports/GameTabs.tsx'
import TeamLogo from '../../../components/sports/TeamLogo.tsx'
import TileFrame from '../../../components/sports/TileFrame.tsx'
import { useApi } from '../../../hooks/useApi.ts'
import { useBack } from '../../../hooks/useBack.ts'
import { useBranding } from '../../../hooks/useBranding.ts'
import { useSportParam } from '../../../hooks/useSportParam.ts'
import { fmt, odds, ordinal, signed, spreadText, titleCase } from '../../../lib/format.ts'
import { PRECIP_FLAG, SPREAD_MOVE_FLAG, WIND_PASSING } from '../../../lib/thresholds.ts'
import { boardPath, useView } from '../../../state/view.tsx'

/** The pond's front door: triage. The matchup header, who is in and out, what
    each defense leaks, the flags worth a click, and doors into the other three
    rooms. One fetch — everything rides the game payload. */
export default function Overview() {
  return (
    <CapabilityGate cap="schedule">
      <OverviewPage />
    </CapabilityGate>
  )
}

function OverviewPage() {
  const sport = useSportParam()
  const { gameKey = '' } = useParams<{ gameKey: string }>()
  const [search] = useSearchParams()
  const vendorParam = search.get('vendor') ?? undefined
  const { view } = useView()

  const res = useApi((signal) => fetchGame(sport, gameKey, vendorParam, signal), [sport, gameKey, vendorParam])
  const boardHref = boardPath(sport, view)
  const back = useBack(boardHref)
  const branding = useBranding(sport)
  const data = res.data

  if (!data) {
    return (
      <div className="page page-game-overview">
        <GameTabs sport={sport} gameKey={gameKey} matchup={res.error ? 'No such game' : '...'} tab="Overview" boardHref={boardHref} back={back} vendorParam={vendorParam} />
        <div className="page-head">
          <h1>{res.error ? 'No such game' : 'Loading...'}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a game from the <Link to={boardHref}>slate</Link>.
            </p>
          )}
        </div>
      </div>
    )
  }

  const g = data.game
  const matchup = `${g.away_team_label} @ ${g.home_team_label}`
  const edges = edgeFlags(g, data, sport, gameKey, vendorParam)
  const homeAvail = data.availability.filter((r) => r.team_key === g.home_team_key)
  const awayAvail = data.availability.filter((r) => r.team_key === g.away_team_key)
  const propCount = new Set([...data.away, ...data.home].map((p) => `${p.player_key}|${p.prop_type}`)).size

  return (
    <div className="page page-game-overview">
      <GameTabs sport={sport} gameKey={gameKey} matchup={matchup} tab="Overview" boardHref={boardHref} back={back} vendorParam={vendorParam} />

      {/* zone 1 · the full matchup header */}
      <div className="game-head" data-tilt="">
        <div className="matchup">
          <span className="kick">
            {g.kickoff_window_label} · {g.kickoff_slot_et} ET{g.is_completed ? ' · final' : ''} ·{' '}
            {g.stadium_name ?? g.venue ?? ''}
          </span>
          <h1>
            <TeamLogo teamKey={g.away_team_key} label={g.away_team_label} branding={branding} /> {g.away_team_name}{' '}
            <span className="at">at</span>{' '}
            <TeamLogo teamKey={g.home_team_key} label={g.home_team_label} branding={branding} /> {g.home_team_name}
          </h1>
          <p className="lede">
            {g.away_team_label} {g.away_record} at {g.home_team_label} {g.home_record}
            {g.is_division_game ? ' · division game' : ''}
            {[g.roof, g.surface].filter(Boolean).length ? ` · ${[g.roof, g.surface].filter(Boolean).join(' · ')}` : ''}
          </p>
        </div>
        <div className="line-strip">
          {g.is_completed ? (
            <>
              <Stat v={`${fmt(g.away_score)}–${fmt(g.home_score)}`} l={`Final${g.went_to_overtime ? ' · OT' : ''}`} />
              <Stat v={g.home_spread_result ? `${g.home_team_label} ${g.home_spread_result}` : '—'} l={`vs spread ${spreadText(g.home_spread)}`} />
              <Stat v={g.total_result ?? '—'} l={`vs total ${fmt(g.total_line, 1)}`} />
            </>
          ) : g.vendor ? (
            <>
              <Stat v={`${g.home_team_label} ${spreadText(g.home_spread)}`} l={`Spread · ${g.vendor}`} />
              <Stat v={fmt(g.total_line, 1)} l="Total" />
              <Stat v={odds(g.away_moneyline_odds)} l={`ML ${g.away_team_label}`} />
              <Stat v={odds(g.home_moneyline_odds)} l={`ML ${g.home_team_label}`} />
            </>
          ) : (
            <Stat v="no line yet" l={data.vendors.length ? `priced at ${data.vendors.join(', ')}` : 'no book has priced it'} />
          )}
          <Stat
            v={g.is_weather_relevant ? (g.kickoff_temp_f !== null ? `${fmt(g.kickoff_temp_f)}°F · ${fmt(g.wind_mph)} mph` : '—') : 'indoors'}
            l="Weather"
          />
          <Stat v={g.referee ?? '—'} l="Referee" />
        </div>
      </div>

      {/* zone 4 · edge flags — rule-based, from signals on this payload */}
      {edges.length > 0 && (
        <TileFrame title="Edge flags" meta="rule-based · no model claims" className="edges-tile">
          <ul className="edges">
            {edges.map((e) => (
              <li key={e.headline}>
                <Link to={e.to}>
                  <b>{e.headline}</b>
                  <small>{e.detail}</small>
                </Link>
              </li>
            ))}
          </ul>
        </TileFrame>
      )}

      {/* zone 2 · availability, one tile per side */}
      <div className="grid cols-game">
        <AvailabilityTile rows={awayAvail} label={g.away_team_label} sport={sport} covered={g.home_players_out !== null} />
        <AvailabilityTile rows={homeAvail} label={g.home_team_label} sport={sport} covered={g.home_players_out !== null} />
      </div>

      {/* zone 3 · what each defense allows (compact) */}
      {data.allowed.length > 0 && (
        <div className="grid cols-game">
          <AllowedTile rows={data.allowed} defenseKey={g.home_team_key} label={g.home_team_label} propsHref={`/${sport}/games/${gameKey}/props`} />
          <AllowedTile rows={data.allowed} defenseKey={g.away_team_key} label={g.away_team_label} propsHref={`/${sport}/games/${gameKey}/props`} />
        </div>
      )}

      {/* zone 5 · doors into the other rooms */}
      <div className="grid teasers">
        <Link className="tile teaser" to={`/${sport}/games/${gameKey}/props${vendorParam ? `?vendor=${vendorParam}` : ''}`}>
          <h2>Prop board</h2>
          <p>
            {propCount > 0 ? `${propCount} props across ${data.vendors.length} book${data.vendors.length === 1 ? '' : 's'}` : 'no props posted yet'}
          </p>
          <span className="go">Open →</span>
        </Link>
        <Link className="tile teaser" to={`/${sport}/games/${gameKey}/situations`}>
          <h2>Situations</h2>
          <p>down · distance · field zone · script, each offense beside what the other defense allows</p>
          <span className="go">Open →</span>
        </Link>
        <Link className="tile teaser" to={`/${sport}/games/${gameKey}/lines${vendorParam ? `?vendor=${vendorParam}` : ''}`}>
          <h2>Lines</h2>
          <p>
            {g.home_spread_movement
              ? `spread ${signed(g.home_spread_movement, 1)} since open · every book's path`
              : 'spread and total since open, every book on one chart'}
          </p>
          <span className="go">Open →</span>
        </Link>
      </div>

      <TileFrame title="How this screen is built" className="note-tile" query={data.query}>
        <p>
          One payload: the game's slate row with the chosen book's line, the prop board (for the
          teasers and flags), the status board bound to this game, and both defenses' allowed rows.
          The flags are rules over those same numbers — wind against the total, a line that moved,
          designations filed, the softest prop lean — never a model's opinion.
        </p>
      </TileFrame>
    </div>
  )
}

function Stat({ v, l }: { v: string; l: string }) {
  return (
    <div className="stat">
      <span className="v">{v || '—'}</span>
      <span className="l">{l}</span>
    </div>
  )
}

function Prac({ code }: { code: string | null }) {
  return <i className={code ?? ''}>{code ?? '·'}</i>
}

function statusBadge(s: StatusRow): string {
  const label = (s.designation ?? s.live_injury_status ?? '').toLowerCase()
  if (label === 'out' || label === 'ir') return 'out'
  if (label === 'doubtful') return 'neg'
  if (label === 'questionable') return 'q'
  return 'acc'
}

function AvailabilityTile({
  rows,
  label,
  sport,
  covered,
}: {
  rows: StatusRow[]
  label: string
  sport: string
  covered: boolean
}) {
  return (
    <TileFrame title={`${label} availability`} meta={rows.length ? `${rows.length} designations` : undefined}>
      {rows.length === 0 ? (
        <p className="hint">{covered ? 'Clean report — nobody carries a designation.' : 'No official report for this game.'}</p>
      ) : (
        <div className="avail">
          {rows.map((s) => (
            <div key={s.app_status_board_key} className="avrow">
              <Link to={`/${sport}/players/${s.player_key}`} className="who">
                <b>{s.player_name}</b>
                <small>{[s.position, s.injury ?? s.live_injury_status].filter(Boolean).join(' · ')}</small>
              </Link>
              <span className={`badge ${statusBadge(s)}`}>{(s.designation ?? s.live_injury_status ?? '?').toUpperCase()}</span>
              <span className="prac">
                <Prac code={s.practice_wed} />
                <Prac code={s.practice_thu} />
                <Prac code={s.practice_fri} />
              </span>
            </div>
          ))}
        </div>
      )}
    </TileFrame>
  )
}

function AllowedTile({
  rows,
  defenseKey,
  label,
  propsHref,
}: {
  rows: AllowedRow[]
  defenseKey: string
  label: string
  propsHref: string
}) {
  const mine = rows
    .filter((r) => r.team_key === defenseKey)
    .sort((a, b) => a.allowed_rank - b.allowed_rank)
  const top = mine.slice(0, 5)
  const season = mine[0]?.season
  return (
    <TileFrame
      title={`What ${label}'s defense allows`}
      meta={season ? `top leaks · ${season} · rank of ${mine[0]?.teams_ranked ?? 32}` : undefined}
      caption={<Link to={propsHref}>The full grid feeds the prop board's DvP column →</Link>}
    >
      {top.length === 0 ? (
        <p className="hint">No allowed rows for this defense yet.</p>
      ) : (
        <div className="allowed">
          {top.map((r) => (
            <div key={r.app_team_allowed_key} className="alrow">
              <span className={`rk ${r.allowed_rank <= 6 ? 'leak' : r.allowed_rank >= r.teams_ranked - 5 ? 'sting' : ''}`}>
                {ordinal(r.allowed_rank)}
              </span>
              <span className="what">
                <b>
                  {r.position} · {titleCase(r.stat_key)}
                </b>
                <small>{signed(r.allowed_vs_league, 1)} vs league</small>
              </span>
              <span className="per">
                {fmt(r.allowed_per_game, 1)}
                <small>/gm</small>
              </span>
            </div>
          ))}
        </div>
      )}
    </TileFrame>
  )
}

interface Edge {
  headline: string
  detail: string
  to: string
}

/** Typed, rule-based flags from the payload's own numbers. Each one deep-links
    the room where the signal lives. No model claims. */
function edgeFlags(g: SlateRow, data: GamePayload, sport: string, gameKey: string, vendorParam: string | undefined): Edge[] {
  const q = vendorParam ? `?vendor=${encodeURIComponent(vendorParam)}` : ''
  const base = `/${sport}/games/${gameKey}`
  const edges: Edge[] = []
  if (g.is_completed) return edges
  if (g.is_weather_relevant && (g.wind_mph ?? 0) >= WIND_PASSING && g.total_line !== null) {
    edges.push({
      headline: `✦ wind ${fmt(g.wind_mph)} mph against a ${fmt(g.total_line, 1)} total`,
      detail: 'passing volume and the over usually shade down in this range',
      to: `${base}/lines${q}`,
    })
  }
  if (g.is_weather_relevant && (g.precip_in ?? 0) >= PRECIP_FLAG) {
    edges.push({
      headline: `rain forecast, ${fmt(g.precip_in, 2)} in`,
      detail: 'handling and kicking props carry extra variance',
      to: `${base}/props${q}`,
    })
  }
  if (Math.abs(g.home_spread_movement ?? 0) >= SPREAD_MOVE_FLAG) {
    const toward = (g.home_spread_movement ?? 0) < 0 ? g.home_team_label : g.away_team_label
    edges.push({
      headline: `✦ spread moved ${signed(g.home_spread_movement, 1)} toward ${toward}`,
      detail: 'player lines on that side often lag the game line',
      to: `${base}/lines${q}`,
    })
  }
  const outs = data.availability.filter((r) => (r.designation ?? '').toLowerCase() === 'out')
  if (outs.length > 0) {
    const names = outs.slice(0, 3).map((r) => r.player_name).join(', ')
    edges.push({
      headline: `${outs.length} ruled out — ${names}${outs.length > 3 ? '…' : ''}`,
      detail: 'the board below shows the full report and the next man up',
      to: `${base}/props${q}`,
    })
  }
  const leans = [...data.away, ...data.home].filter((p) => p.has_projection && p.projection_vs_line !== null)
  if (leans.length > 0) {
    const soft = leans.reduce((a, b) => (Math.abs(b.projection_vs_line!) > Math.abs(a.projection_vs_line!) ? b : a))
    edges.push({
      headline: `✦ softest prop: ${soft.player_name} ${soft.stat_label ?? soft.prop_type} ${signed(soft.projection_vs_line, 1)}`,
      detail: `Sleeper ${fmt(soft.projection_value, 1)} vs the ${fmt(soft.line_value, 1)} line at ${soft.vendor}`,
      to: `${base}/props${q}`,
    })
  }
  if (g.is_division_game) {
    edges.push({
      headline: 'division game',
      detail: 'familiarity compresses spreads; situational splits matter more',
      to: `${base}/situations`,
    })
  }
  return edges
}
