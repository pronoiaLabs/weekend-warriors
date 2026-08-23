import { Link, useParams, useSearchParams } from 'react-router-dom'
import { fetchLeaders, fetchTeam } from '../../api/sports/client.ts'
import type { AllowedRow, AtsRow, LeadersRow, StandingsRow, TeamWeekRow } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import Crumbs from '../../components/sports/Crumbs.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBack } from '../../hooks/useBack.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, ordinal, pct, signed, spreadText, titleCase, tone } from '../../lib/format.ts'
import { LEADER_COLS, groupOf } from '../../lib/positions.ts'
import { useView } from '../../state/view.tsx'
import { record } from './Teams.tsx'

const POSITION_ORDER = ['QB', 'RB', 'WR', 'TE']
const STAT_LABELS: Record<string, string> = {
  passing_yards: 'Passing yards',
  passing_touchdowns: 'Passing TDs',
  rushing_yards: 'Rushing yards',
  receiving_yards: 'Receiving yards',
  receptions: 'Receptions',
  scoring_touchdowns: 'Rushing + receiving TDs',
}

export default function Team() {
  return (
    <CapabilityGate cap="team_standings">
      <TeamPage />
    </CapabilityGate>
  )
}

function TeamPage() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const { team = '' } = useParams<{ team: string }>()
  const [search, setSearch] = useSearchParams()
  const { view, setView } = useView()

  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : undefined
  const seasonType = search.get('season_type') ?? undefined
  // the book: the URL's, else the one remembered from the board
  const vendor = search.get('vendor') ?? view.vendor

  const res = useApi(
    (signal) => fetchTeam(sport, team, { season, season_type: seasonType, vendor }, signal),
    [sport, team, season, seasonType, vendor],
  )
  // the roster: the leaders route with the team bound, once the team's own
  // payload has resolved which season type is being shown
  const resolvedType = res.data?.season_type_name
  const hasLeaders = caps?.capabilities.includes('player_leaders') ?? false
  const roster = useApi(
    (signal) =>
      hasLeaders && resolvedType
        ? fetchLeaders(sport, { season, season_type: resolvedType, team }, signal)
        : Promise.resolve(null),
    [sport, team, season, resolvedType, hasLeaders],
  )

  const standingsSearch = (() => {
    const p = new URLSearchParams()
    if (season !== undefined) p.set('season', String(season))
    if (seasonType) p.set('season_type', seasonType)
    const qs = p.toString()
    return qs ? `?${qs}` : ''
  })()
  const standingsHref = `/${sport}/teams${standingsSearch}`
  const back = useBack(standingsHref)

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
      <div className="page page-team">
        <Crumbs items={[{ label: 'Teams', to: standingsHref }, { label: res.error ? 'No such team' : team.toUpperCase() }]} />
        <div className="page-head">
          <h1>{res.error ? 'No such team' : 'Loading...'}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a team from the <Link to={standingsHref}>standings</Link>.
            </p>
          )}
        </div>
      </div>
    )
  }

  const t = data.team
  const ats = data.ats.find((a) => a.vendor === data.vendor) ?? null

  return (
    <div className="page page-team">
      <div className="crumb-row">
        <Crumbs items={[{ label: 'Teams', to: standingsHref }, { label: t.team_name }]} />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to standings
        </button>
      </div>

      <div className="team-head" data-tilt="">
        <div className="ident">
          <span className="kick">
            {[t.conference, t.division].filter(Boolean).join(' ')} · {t.season_type_name.toLowerCase()} {t.season}
          </span>
          <h1>
            {t.team_name} <span className="at">{t.team_label}</span>
          </h1>
          <p className="lede">
            {record(t)}, {ordinal(t.rank_overall)} overall, {ordinal(t.rank_conference)} in the {t.conference ?? 'conference'},{' '}
            {ordinal(t.rank_division)} in the division. Last three: {(t.last_results ?? []).join(' ') || 'none'}.
          </p>
        </div>
        <div className="line-strip">
          <Stat v={fmt(t.points_for_per_game, 1)} l="Points for / game" />
          <Stat v={fmt(t.points_against_per_game, 1)} l="Points against / game" />
          <Stat v={signed(t.point_diff_per_game, 1)} l="Differential / game" cls={tone(t.point_diff_per_game)} />
          <Stat v={fmt(t.yards_per_play, 2)} l="Yards per play" />
          <Stat v={fmt(t.opp_yards_per_play, 2)} l="Allowed per play" />
          <Stat v={pct(t.third_down_pct)} l="Third down" />
          <Stat v={pct(t.red_zone_pct)} l="Red zone" />
          <Stat v={signed(t.turnover_margin, 0)} l="Turnover margin" cls={tone(t.turnover_margin)} />
        </div>
      </div>

      <div className="filters">
        <Chips
          label="Season type"
          items={data.season_types.map((s) => ({ id: s, label: s }))}
          active={data.season_type_name}
          onPick={(id) => set({ season_type: id })}
        />
        {caps && caps.vendors.length > 0 && (
          <Chips
            label="Book"
            items={caps.vendors.map((v) => ({ id: v, label: v }))}
            active={data.vendor}
            onPick={(id) => {
              setView({ vendor: id === caps.default_vendor ? undefined : id })
              set({ vendor: id === caps.default_vendor ? undefined : id })
            }}
          />
        )}
      </div>

      <div className="grid cols-team">
        <TileFrame title="Splits" meta={`${t.games} games`} className="splits-tile">
          <SplitsTable rows={data.splits} />
        </TileFrame>
        <TileFrame title="Margin by game" meta={data.season_type_name} className="margin-tile" caption="Bars are the final margin; the line is the closing spread from this team's side when the book priced the game.">
          <MarginChart weeks={data.weeks} />
        </TileFrame>
      </div>

      <TileFrame
        title="Season"
        meta={`${data.weeks.length} games · lines from ${data.vendor ?? 'no book'}`}
        className="weeks-tile"
        caption={
          data.vendors.length === 0
            ? 'No closing lines for these games: the odds feed begins with the 2026 regular season.'
            : `Spread is this team's number (negative when favoured). ATS and the total are settled against the final score. Books with a line this season type: ${data.vendors.join(', ')}.`
        }
      >
        <WeeksTable weeks={data.weeks} sport={sport} vendor={data.vendor} />
      </TileFrame>

      <div className="grid cols-team">
        <TileFrame
          title="What the defense allows"
          meta={`rank 1 allows the most of ${data.allowed[0]?.teams_ranked ?? 32}`}
          className="allowed-tile"
          caption="Opposing players' box scores attributed to this defense, by the player's position. The same rows feed the matchup column on the game prop board."
        >
          <AllowedTable rows={data.allowed} />
        </TileFrame>
        <TileFrame title="Against the number" meta={ats ? `${ats.games_with_line} lined games at ${ats.vendor}` : data.vendor ?? ''} className="ats-tile">
          {ats ? (
            <AtsPanel a={ats} />
          ) : (
            <p className="hint">
              {data.ats.length
                ? `No ${data.vendor} lines this season type; priced at ${data.ats.map((a) => a.vendor).join(', ')}.`
                : 'No closing lines settled yet for this season type. The record against the spread appears once a lined game is played.'}
            </p>
          )}
        </TileFrame>
      </div>

      {hasLeaders && (
        <TileFrame
          title="Roster"
          meta={roster.data ? `${roster.data.rows.length} players with a game` : '...'}
          className="table-tile"
          query={roster.data?.query}
          caption="Everyone with a box score for this team in the season type, by position. Ranks are within the position across the league."
        >
          {roster.data ? <RosterTable rows={roster.data.rows} sport={sport} seasonType={data.season_type_name} season={data.season} /> : <p className="hint">{roster.error ?? 'Loading the roster...'}</p>}
        </TileFrame>
      )}

      <TileFrame title="How this page is built" className="note-tile" query={data.query}>
        <p>
          Four selects on the team's label: the standings mart for every split, the team weeks mart across every
          book (collapsed here to one row per game carrying the chosen book's closing line from this team's side),
          the defense-allowed mart by position and stat, and the against-the-spread mart per book. The season type
          defaults to the one whose most recent game is latest.
        </p>
      </TileFrame>
    </div>
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

function SplitsTable({ rows }: { rows: StandingsRow[] }) {
  const order = ['all', 'home', 'away']
  const sorted = [...rows].sort((a, b) => order.indexOf(a.split) - order.indexOf(b.split))
  return (
    <div className="splits">
      <div className="split-row head">
        <span>Split</span>
        <span className="n">G</span>
        <span className="n">W-L-T</span>
        <span className="n">PF/G</span>
        <span className="n">PA/G</span>
        <span className="n">Diff/G</span>
        <span className="n">YPP</span>
        <span className="n">Opp YPP</span>
      </div>
      {sorted.map((r) => (
        <div key={r.split} className="split-row">
          <span className="tm">{titleCase(r.split)}</span>
          <span className="n">{r.games}</span>
          <span className="n">{record(r)}</span>
          <span className="n">{fmt(r.points_for_per_game, 1)}</span>
          <span className="n">{fmt(r.points_against_per_game, 1)}</span>
          <span className={`n ${tone(r.point_diff_per_game)}`}>{signed(r.point_diff_per_game, 1)}</span>
          <span className="n">{fmt(r.yards_per_play, 2)}</span>
          <span className="n">{fmt(r.opp_yards_per_play, 2)}</span>
        </div>
      ))}
    </div>
  )
}

/** Inline SVG, no chart library: one bar per game for the final margin, a tick
    where the closing spread sat (negated, so the tick is the margin the team
    needed). Scaled to the largest absolute value on the page. */
function MarginChart({ weeks }: { weeks: TeamWeekRow[] }) {
  if (weeks.length === 0) return <p className="hint">No games played yet.</p>
  const W = 600
  const H = 160
  const pad = 8
  const values = weeks.flatMap((w) => [Math.abs(w.point_margin), w.spread === null ? 0 : Math.abs(w.spread)])
  const max = Math.max(7, ...values)
  const mid = H / 2
  const scale = (mid - pad) / max
  const slot = (W - pad * 2) / weeks.length
  const bw = Math.max(4, Math.min(22, slot * 0.6))
  return (
    <svg className="margin-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Point margin by game">
      <line x1={pad} x2={W - pad} y1={mid} y2={mid} className="axis" />
      {weeks.map((w, i) => {
        const x = pad + slot * i + (slot - bw) / 2
        const h = Math.abs(w.point_margin) * scale
        const y = w.point_margin >= 0 ? mid - h : mid
        const need = w.spread === null ? null : mid + w.spread * scale
        return (
          <g key={w.game_key}>
            <title>
              {`Week ${w.week} ${w.is_home ? 'vs' : 'at'} ${w.opponent_label ?? ''}: ${w.result ?? ''} ${w.points_for}-${w.points_against}${
                w.spread === null ? '' : `, spread ${spreadText(w.spread)}, ${w.spread_result ?? ''}`
              }`}
            </title>
            <rect x={x} y={y} width={bw} height={Math.max(1, h)} className={`bar ${w.point_margin >= 0 ? 'pos' : 'neg'}`} />
            {need !== null && <line x1={x - 2} x2={x + bw + 2} y1={need} y2={need} className="need" />}
            <text x={x + bw / 2} y={H - 1} className="lbl" textAnchor="middle">
              {w.week}
            </text>
          </g>
        )
      })}
    </svg>
  )
}

function WeeksTable({ weeks, sport, vendor }: { weeks: TeamWeekRow[]; sport: string; vendor: string | null }) {
  if (weeks.length === 0) return <p className="hint">No games played yet in this season type.</p>
  return (
    <div className="weeks">
      <div className="week-row head">
        <span className="n">Wk</span>
        <span>Opponent</span>
        <span>Result</span>
        <span className="n">Margin</span>
        <span className="n">Record</span>
        <span className="n">Yds</span>
        <span className="n">Allowed</span>
        <span className="n">TO</span>
        <span className="n">Spread</span>
        <span className="n">ATS</span>
        <span className="n">Total</span>
      </div>
      {weeks.map((w) => (
        <Link key={w.game_key} className="week-row" to={`/${sport}/games/${w.game_key}${vendor ? `?vendor=${encodeURIComponent(vendor)}` : ''}`}>
          <span className="n rk">{w.week}</span>
          <span className="tm">
            <b>
              {w.is_home ? 'vs' : 'at'} {w.opponent_label}
            </b>
            <small>{w.kickoff_slot_et} ET</small>
          </span>
          <span className={`tm ${w.result === 'W' ? 'pos' : w.result === 'L' ? 'neg' : ''}`}>
            <b>
              {w.result} {w.points_for}-{w.points_against}
              {w.went_to_overtime ? ' OT' : ''}
            </b>
          </span>
          <span className={`n ${tone(w.point_margin)}`}>{signed(w.point_margin, 0)}</span>
          <span className="n">{w.ties_to_date ? `${w.wins_to_date}-${w.losses_to_date}-${w.ties_to_date}` : `${w.wins_to_date}-${w.losses_to_date}`}</span>
          <span className="n">{fmt(w.total_yards)}</span>
          <span className="n">{fmt(w.opp_total_yards)}</span>
          <span className={`n ${tone(w.turnover_margin)}`}>{signed(w.turnover_margin, 0)}</span>
          <span className="n">{w.spread === null ? (w.vendors_available.length ? `at ${w.vendors_available.length} other` : '') : spreadText(w.spread)}</span>
          <span className={`n ${w.spread_result === 'cover' ? 'pos' : w.spread_result === 'loss' ? 'neg' : ''}`}>{w.spread_result ?? ''}</span>
          <span className="n">{w.total_line === null ? '' : `${fmt(w.total_line, 1)} ${w.total_result ?? ''}`}</span>
        </Link>
      ))}
    </div>
  )
}

function AllowedTable({ rows }: { rows: AllowedRow[] }) {
  if (rows.length === 0) return <p className="hint">No opposing box scores yet.</p>
  const sorted = [...rows].sort(
    (a, b) => POSITION_ORDER.indexOf(a.position) - POSITION_ORDER.indexOf(b.position) || a.stat_key.localeCompare(b.stat_key),
  )
  return (
    <div className="allowed">
      <div className="allowed-row head">
        <span>Pos</span>
        <span>Stat</span>
        <span className="n">Per game</span>
        <span className="n">League</span>
        <span className="n">vs league</span>
        <span className="n">Rank</span>
      </div>
      {sorted.map((r) => {
        const soft = r.allowed_rank <= Math.ceil(r.teams_ranked / 4)
        const stingy = r.allowed_rank > r.teams_ranked - Math.ceil(r.teams_ranked / 4)
        return (
          <div key={r.app_team_allowed_key} className="allowed-row">
            <span className="rk">{r.position}</span>
            <span className="tm">{STAT_LABELS[r.stat_key] ?? titleCase(r.stat_key)}</span>
            <span className="n">{fmt(r.allowed_per_game, r.stat_key.endsWith('touchdowns') ? 2 : 1)}</span>
            <span className="n">{fmt(r.league_avg_per_game, r.stat_key.endsWith('touchdowns') ? 2 : 1)}</span>
            <span className={`n ${tone(r.allowed_vs_league)}`}>{signed(r.allowed_vs_league, r.stat_key.endsWith('touchdowns') ? 2 : 1)}</span>
            <span className={`n ${soft ? 'neg' : stingy ? 'pos' : ''}`}>
              {ordinal(r.allowed_rank)}
              <small> of {r.teams_ranked}</small>
            </span>
          </div>
        )
      })}
    </div>
  )
}

const ROSTER_ORDER = ['QB', 'RB', 'WR', 'TE']

function RosterTable({ rows, sport, season, seasonType }: { rows: LeadersRow[]; sport: string; season: number; seasonType: string }) {
  if (rows.length === 0) return <p className="hint">No box scores yet.</p>
  const sorted = [...rows].sort((a, b) => {
    const ga = ROSTER_ORDER.indexOf(a.position ?? ''),
      gb = ROSTER_ORDER.indexOf(b.position ?? '')
    return (ga === -1 ? 9 : ga) - (gb === -1 ? 9 : gb) || (b.fanduel_points ?? 0) - (a.fanduel_points ?? 0)
  })
  const href = (r: LeadersRow) => `/${sport}/players/${r.player_key}?season=${season}&season_type=${encodeURIComponent(seasonType)}`
  return (
    <div className="trows" style={{ '--cols': 'minmax(150px, 1.8fr) 40px 40px repeat(4, minmax(70px, 1fr))' } as React.CSSProperties}>
      <div className="trow head">
        <span>Player</span>
        <span>Pos</span>
        <span className="n">G</span>
        <span className="n">Headline</span>
        <span className="n">Second</span>
        <span className="n">FD pts</span>
        <span className="n">FD rank</span>
      </div>
      {sorted.map((r) => {
        const cols = LEADER_COLS[groupOf(r.position)].filter((c) => c.rank)
        const [first, second] = [cols[0], cols[1]]
        return (
          <Link key={r.player_key} className="trow" to={href(r)}>
            <span className="tm">
              <b>{r.player_name}</b>
              <small>{r.position_name ?? r.position}</small>
            </span>
            <span className="rk">{r.position}</span>
            <span className="n">{r.games}</span>
            <span className="n">
              {first ? fmt(r[first.key] as number | null, first.digits ?? 0) : ''}
              <small> {first?.label}</small>
            </span>
            <span className="n">
              {second ? fmt(r[second.key] as number | null, second.digits ?? 0) : ''}
              <small> {second?.label}</small>
            </span>
            <span className="n">{fmt(r.fanduel_points, 1)}</span>
            <span className="n">
              {ordinal(r.rank_fanduel_points)}
              <small> of {r.players_at_position}</small>
            </span>
          </Link>
        )
      })}
    </div>
  )
}

function AtsPanel({ a }: { a: AtsRow }) {
  return (
    <div className="line-strip ats">
      <Stat v={`${a.ats_wins}-${a.ats_losses}${a.ats_pushes ? `-${a.ats_pushes}` : ''}`} l="Against the spread" />
      <Stat v={pct(a.ats_pct)} l="Cover rate" cls={a.ats_pct === null ? '' : a.ats_pct > 0.5 ? 'pos' : a.ats_pct < 0.5 ? 'neg' : ''} />
      <Stat v={`${a.overs}-${a.unders}${a.total_pushes ? `-${a.total_pushes}` : ''}`} l="Over-under" />
      <Stat v={signed(a.avg_margin_vs_spread, 1)} l="Avg margin vs spread" cls={tone(a.avg_margin_vs_spread)} />
      <Stat v={`${a.favourite_ats_wins}-${a.favourite_games - a.favourite_ats_wins}`} l={`As favourite (${a.favourite_games})`} />
      <Stat v={`${a.underdog_ats_wins}-${a.underdog_games - a.underdog_ats_wins}`} l={`As underdog (${a.underdog_games})`} />
      <Stat v={`${a.home_ats_wins}-${a.home_ats_losses}`} l="ATS at home" />
      <Stat v={`${a.away_ats_wins}-${a.away_ats_losses}`} l="ATS away" />
      <Stat v={spreadText(a.avg_spread)} l="Avg closing spread" />
      <Stat v={fmt(a.avg_total_line, 1)} l="Avg closing total" />
      <Stat v={signed(a.avg_total_vs_line, 1)} l="Avg total vs line" cls={tone(a.avg_total_vs_line)} />
    </div>
  )
}
