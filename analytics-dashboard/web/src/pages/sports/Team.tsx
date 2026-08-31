import { Link, useParams, useSearchParams } from 'react-router-dom'
import { fetchLeaders, fetchSlate, fetchTeam } from '../../api/sports/client.ts'
import type { AllowedRow, LeadersRow, SituationRow, SlateRow, TeamWeekRow } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import Crumbs from '../../components/sports/Crumbs.tsx'
import TeamLogo from '../../components/sports/TeamLogo.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBack } from '../../hooks/useBack.ts'
import { teamAccent, useBranding } from '../../hooks/useBranding.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, ordinal, pct, signed, spreadText, tone } from '../../lib/format.ts'
import { LEADER_COLS, groupOf } from '../../lib/positions.ts'
import { useView } from '../../state/view.tsx'
import { epaCell, record } from './Teams.tsx'

export default function Team() {
  return (
    <CapabilityGate cap="team_standings">
      <TeamPage />
    </CapabilityGate>
  )
}

/** One team under the glass: week-by-week EPA, what the defense allows by
    position, how the market has graded them, and where they live and die by
    situation. Team color stays a whisper -- the 3px bar, never a flood. */
function TeamPage() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const branding = useBranding(sport)
  const { team = '' } = useParams<{ team: string }>()
  const [search, setSearch] = useSearchParams()
  const { view, setView } = useView()

  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : undefined
  const seasonType = search.get('season_type') ?? undefined
  const vendor = search.get('vendor') ?? view.vendor

  const res = useApi(
    (signal) => fetchTeam(sport, team, { season, season_type: seasonType, vendor }, signal),
    [sport, team, season, seasonType, vendor],
  )
  const resolvedType = res.data?.season_type_name
  const hasLeaders = caps?.capabilities.includes('player_leaders') ?? false
  const roster = useApi(
    (signal) =>
      hasLeaders && resolvedType
        ? fetchLeaders(sport, { season, season_type: resolvedType, team }, signal)
        : Promise.resolve(null),
    [sport, team, season, resolvedType, hasLeaders],
  )
  // the team's next game rides at the bottom of the week log; the current
  // week's slate is the source, so it only exists for the season in progress
  const hasSlate = caps?.capabilities.includes('schedule') ?? false
  const slate = useApi(
    (signal) => (hasSlate ? fetchSlate(sport, { vendor }, signal) : Promise.resolve(null)),
    [sport, hasSlate, vendor],
  )
  const label = team.toUpperCase()
  const upNext =
    slate.data?.rows.find(
      (g) => !g.is_completed && (g.home_team_label === label || g.away_team_label === label),
    ) ?? null

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
        <Crumbs items={[{ label: 'Teams', to: standingsHref }, { label: res.error ? 'No such team' : label }]} />
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
  const brand = branding.get(t.team_key)
  const accent = teamAccent(brand)
  const ats = data.ats.find((a) => a.vendor === data.vendor) ?? null
  const off = epaCell(t.off_epa_per_play)
  const def = epaCell(t.def_epa_per_play, true)
  const propsHref = upNext ? `/${sport}/games/${upNext.game_key}/props` : `/${sport}/slate`

  return (
    <div className="page page-team">
      <div className="crumb-row">
        <Crumbs items={[{ label: 'Teams', to: standingsHref }, { label: t.team_name }]} />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to standings
        </button>
      </div>

      {/* the identity head: rank, record, the four numbers that frame a matchup */}
      <header
        className="team-head team-page-head"
        data-tilt=""
        style={accent ? ({ '--team': accent } as React.CSSProperties) : undefined}
      >
        <span className="team-bar" aria-hidden="true" />
        <div className="ident">
          <span className="kick">
            {[t.conference, t.division].filter(Boolean).join(' ')} · {ordinal(t.rank_division)} place ·{' '}
            {t.season_type_name.toLowerCase()} {t.season}
          </span>
          <h1>{t.team_name}</h1>
          <div className="id-row">
            <TeamLogo teamKey={t.team_key} label={t.team_label} branding={branding} size="xl" />
            <span className="rec">
              <b>{record(t)}</b>
              <small>
                {fmt(t.points_for)} PF · {fmt(t.points_against)} PA
              </small>
            </span>
            <span className="last">
              <small>Last 5</small>
              {[...(t.last_results ?? [])].reverse().map((x, i) => (
                <i key={i} className={`res ${x}`}>
                  {x}
                </i>
              ))}
            </span>
            {brand?.wordmark_url && <img className="wordmark" src={brand.wordmark_url} alt="" loading="lazy" />}
          </div>
        </div>
        <div className="line-strip">
          <Stat
            v={off.text}
            l={`Off EPA / play${t.off_epa_per_play_rank ? ` · ${ordinal(t.off_epa_per_play_rank)}` : ''}`}
            cls={off.cls}
          />
          <Stat
            v={def.text}
            l={`Def EPA / play${t.def_epa_per_play_rank ? ` · ${ordinal(t.def_epa_per_play_rank)}` : ''}`}
            cls={def.cls}
          />
          <Stat v={signed(t.point_diff, 0)} l={`Point diff · ${ordinal(t.rank_overall)} overall`} cls={tone(t.point_diff)} />
          <Stat
            v={ats ? `${ats.ats_wins}-${ats.ats_losses}${ats.ats_pushes ? `-${ats.ats_pushes}` : ''}` : '—'}
            l={`ATS · ${data.vendor ?? 'no book'}`}
          />
        </div>
      </header>

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

      <TileFrame
        title="Week by week"
        meta="rows open game detail"
        className="weeks-tile"
        caption="EPA per play from play-by-play (pass per dropback, rush per carry); defensive EPA reads inverted — negative is good. Preseason rows have no play-by-play and show dashes."
      >
        <WeeksTable weeks={data.weeks} sport={sport} vendor={data.vendor} branding={branding} upNext={upNext} label={label} />
      </TileFrame>

      <div className="grid cols-team">
        <TileFrame
          title={`Defense — what ${label} allows`}
          meta="rank of 32 · cells open the prop board"
          className="allowed-tile"
          caption={allowedCaption(data.allowed, label)}
        >
          <AllowedGrid rows={data.allowed} vendor={data.vendor} propsHref={propsHref} />
        </TileFrame>
        <div className="stack">
          <TileFrame title="Against the market" meta={ats ? `${ats.vendor} · closing` : (data.vendor ?? '')} className="ats-tile">
            {ats ? (
              <div className="line-strip ats">
                <Stat
                  v={`${ats.ats_wins}-${ats.ats_losses}${ats.ats_pushes ? `-${ats.ats_pushes}` : ''}`}
                  l="ATS record"
                  cls={ats.ats_pct === null ? '' : ats.ats_pct > 0.5 ? 'pos' : ats.ats_pct < 0.5 ? 'neg' : ''}
                />
                <Stat v={`${ats.overs}-${ats.unders}${ats.total_pushes ? `-${ats.total_pushes}` : ''}`} l="Over / under" />
                <Stat v={signed(ats.avg_margin_vs_spread, 1)} l="Avg cover margin" cls={tone(ats.avg_margin_vs_spread)} />
                <Stat v={spreadText(ats.avg_spread)} l="Avg spread" />
              </div>
            ) : (
              <p className="hint">
                {data.ats.length
                  ? `No ${data.vendor} lines this season type; priced at ${data.ats.map((a) => a.vendor).join(', ')}.`
                  : 'No closing lines settled yet for this season type. The record against the spread appears once a lined game is played.'}
              </p>
            )}
          </TileFrame>
          <TileFrame
            title="Weekly margin"
            meta="points for − against"
            className="margin-tile"
            caption="Bars are the final margin; the tick is the closing spread from this team's side when the book priced the game."
          >
            <MarginChart weeks={data.weeks} />
          </TileFrame>
        </div>
      </div>

      <TileFrame
        title="Situation splits"
        meta="EPA / play · rows open the play log"
        className="splits-tile"
        caption="Rank 1 is the best unit in the situation for the season type. Postseason pages read the regular-season splits; the preseason has no play-by-play."
      >
        <SituationSplits rows={data.situations} sport={sport} label={label} season={data.season} />
      </TileFrame>

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
          Five selects on the team's label: the standings mart for every split (the head reads the
          all-games row, home and away ride it), the team weeks mart across every book collapsed to the
          chosen book's line, the defense-allowed mart by position and stat (the same rows behind the prop
          board's matchup column), the against-the-spread mart per book, and the situation splits. The
          upcoming game at the bottom of the week log is the current slate's row for this team.
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

/* ---- week by week ---- */

function WeeksTable({
  weeks,
  sport,
  vendor,
  branding,
  upNext,
  label,
}: {
  weeks: TeamWeekRow[]
  sport: string
  vendor: string | null
  branding: ReturnType<typeof useBranding>
  upNext: SlateRow | null
  label: string
}) {
  if (weeks.length === 0 && !upNext) return <p className="hint">No games played yet in this season type.</p>
  return (
    <div className="weeks">
      <div className="week-row head">
        <span className="n">Wk</span>
        <span>Opponent</span>
        <span>Result</span>
        <span className="n">Off EPA</span>
        <span className="n">Def EPA</span>
        <span className="n">Succ%</span>
        <span className="n">Pass EPA</span>
        <span className="n">Rush EPA</span>
        <span className="n">Expl%</span>
        <span className="n">3rd%</span>
        <span className="n">Margin</span>
      </div>
      {weeks.map((w) => {
        const off = epaCell(w.off_epa_per_play)
        const def = epaCell(w.def_epa_per_play, true)
        const pass = epaCell(w.pass_epa_per_dropback)
        const rush = epaCell(w.rush_epa_per_carry)
        return (
          <Link key={w.game_key} className="week-row" to={`/${sport}/games/${w.game_key}${vendor ? `?vendor=${encodeURIComponent(vendor)}` : ''}`} title="Open game detail">
            <span className="n rk">{w.week}</span>
            <span className="opp">
              <TeamLogo teamKey={w.opponent_team_key} label={null} branding={branding} size="sm" />
              <b>
                {w.is_home ? 'vs' : '@'} {w.opponent_label}
              </b>
            </span>
            <span className={`tm ${w.result === 'W' ? 'pos' : w.result === 'L' ? 'neg' : ''}`}>
              <b>
                {w.result} {w.points_for}-{w.points_against}
                {w.went_to_overtime ? ' OT' : ''}
              </b>
            </span>
            <span className={`n ${off.cls}`}>{off.text}</span>
            <span className={`n ${def.cls}`}>{def.text}</span>
            <span className="n">{w.success_rate === null ? '—' : (w.success_rate * 100).toFixed(0)}</span>
            <span className={`n ${pass.cls}`}>{pass.text}</span>
            <span className={`n ${rush.cls}`}>{rush.text}</span>
            <span className="n">{w.explosive_rate === null ? '—' : (w.explosive_rate * 100).toFixed(0)}</span>
            <span className="n">{w.third_down_pct === null ? '—' : (w.third_down_pct * 100).toFixed(0)}</span>
            <span className={`n ${tone(w.point_margin)}`}>{signed(w.point_margin, 0)}</span>
          </Link>
        )
      })}
      {upNext && (
        <Link className="week-row up" to={`/${sport}/games/${upNext.game_key}`} title="Open the game's overview">
          <span className="n rk">{upNext.week}</span>
          <span className="opp">
            <TeamLogo
              teamKey={upNext.home_team_label === label ? upNext.away_team_key : upNext.home_team_key}
              label={null}
              branding={branding}
              size="sm"
            />
            <b>
              {upNext.home_team_label === label ? 'vs' : '@'}{' '}
              {upNext.home_team_label === label ? upNext.away_team_label : upNext.home_team_label}
            </b>
          </span>
          <span className="tm">
            <b>{upNext.kickoff_slot_et}</b>
            <small>
              {upNext.vendor
                ? `${spreadText(upNext.home_team_label === label ? upNext.home_spread : upNext.away_spread)} · ${fmt(upNext.total_line, 1)}`
                : 'no line yet'}
            </small>
          </span>
          {Array.from({ length: 8 }, (_, i) => (
            <span key={i} className="n">
              —
            </span>
          ))}
        </Link>
      )}
    </div>
  )
}

/* ---- the margin chart (bars vs the closing spread's tick) ---- */

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

/* ---- the allowed grid: four rows, QB to TE ---- */

const POSITION_SUB: Record<string, string> = {
  QB: 'pass defense',
  RB: 'run defense',
  WR: 'perimeter coverage',
  TE: 'seam coverage',
}
const YDS_KEY: Record<string, string> = {
  QB: 'passing_yards',
  RB: 'rushing_yards',
  WR: 'receiving_yards',
  TE: 'receiving_yards',
}
const TD_KEY: Record<string, string> = {
  QB: 'passing_touchdowns',
  RB: 'scoring_touchdowns',
  WR: 'scoring_touchdowns',
  TE: 'scoring_touchdowns',
}
const EFF_KEY: Record<string, string> = {
  QB: 'passing_yards_per_attempt',
  RB: 'rushing_yards_per_carry',
  WR: 'receiving_yards_per_target',
  TE: 'receiving_yards_per_target',
}
const EFF_UNIT: Record<string, string> = { QB: 'y/att', RB: 'ypc', WR: 'y/tgt', TE: 'y/tgt' }

/** The page speaks stingy-ordering ("26th" = a defense to attack): the mart's
    rank 1 allows the MOST, so display rank = teams_ranked - rank + 1. */
function stingy(r: AllowedRow | undefined): number | null {
  if (!r) return null
  return r.teams_ranked - r.allowed_rank + 1
}

function allowedCaption(rows: AllowedRow[], label: string): string {
  const fpts = ['QB', 'RB', 'WR', 'TE']
    .map((p) => rows.find((r) => r.position === p && r.stat_key === 'draftkings_points'))
    .filter((r): r is AllowedRow => r !== undefined)
  const leak = fpts.reduce<AllowedRow | null>((a, b) => (a === null || b.allowed_rank < a.allowed_rank ? b : a), null)
  if (!leak) return 'Opposing players’ box scores attributed to this defense, by position.'
  return `Where ${label} bends: ${leak.position}s take the most fantasy points off this defense. The prop angle starts there.`
}

function AllowedGrid({ rows, vendor, propsHref }: { rows: AllowedRow[]; vendor: string | null; propsHref: string }) {
  if (rows.length === 0) return <p className="hint">No opposing box scores yet.</p>
  const fptsKey = vendor === 'fanduel' ? 'fanduel_points' : 'draftkings_points'
  const by = (pos: string, key: string) => rows.find((r) => r.position === pos && r.stat_key === key)
  return (
    <div className="allowed">
      <div className="allowed-row head">
        <span>Rk</span>
        <span>Vs position</span>
        <span className="n">Yds/gm</span>
        <span className="n">TD/gm</span>
        <span className="n">Eff</span>
        <span className="n">Fpts/gm</span>
      </div>
      {['QB', 'RB', 'WR', 'TE'].map((pos) => {
        const yds = by(pos, YDS_KEY[pos]!)
        const td = by(pos, TD_KEY[pos]!)
        const eff = by(pos, EFF_KEY[pos]!)
        const fpts = by(pos, fptsKey)
        const rk = stingy(fpts)
        const badge = rk === null ? '' : rk >= 25 ? 'neg' : rk <= 8 ? 'ok' : ''
        return (
          <div key={pos} className="allowed-row">
            <span>
              <span className={`badge ${badge}`}>{rk ?? '—'}</span>
            </span>
            <span className="tm">
              <b>{pos}</b>
              <small>{POSITION_SUB[pos]}</small>
            </span>
            <AllowedCell r={yds} digits={1} propsHref={propsHref} />
            <AllowedCell r={td} digits={2} propsHref={propsHref} />
            <AllowedCell r={eff} digits={1} unit={EFF_UNIT[pos]} propsHref={propsHref} />
            <AllowedCell r={fpts} digits={1} propsHref={propsHref} />
          </div>
        )
      })}
    </div>
  )
}

function AllowedCell({ r, digits, unit, propsHref }: { r: AllowedRow | undefined; digits: number; unit?: string; propsHref: string }) {
  if (!r) return <span className="n">—</span>
  const rk = stingy(r)
  return (
    <span className="n">
      <Link to={propsHref} title="Open the prop board">
        {fmt(r.allowed_per_game, digits)}
        {unit ? ` ${unit}` : ''}
        <small>{rk === null ? '' : ordinal(rk)}</small>
      </Link>
    </span>
  )
}

/* ---- situation splits ---- */

const CUTS: { key: string; label: string; params: Record<string, string> }[] = [
  { key: '1st', label: '1st down', params: { down_bucket: '1st' } },
  { key: '2nd_long', label: '2nd & long', params: { down_bucket: '2nd', distance_bucket: 'long' } },
  { key: '3rd_4th_short', label: '3rd & short', params: { down_bucket: '3rd_4th', distance_bucket: 'short' } },
  { key: '3rd_4th_long', label: '3rd & long', params: { down_bucket: '3rd_4th', distance_bucket: 'long' } },
  { key: 'red_zone', label: 'Red zone', params: { field_zone: 'red_zone' } },
  { key: 'two_minute', label: 'Two-minute', params: { two_minute: 'true' } },
]

function SituationSplits({ rows, sport, label, season }: { rows: SituationRow[]; sport: string; label: string; season: number }) {
  if (rows.length === 0)
    return <p className="hint">No play-by-play for this season type — the splits cover the regular season and playoffs.</p>
  const find = (side: string, key: string) => rows.find((r) => r.side === side && r.situation_key === key)
  return (
    <div className="splits">
      <div className="split-row head">
        <span>Situation</span>
        <span className="n">Off EPA</span>
        <span className="n">Off SR%</span>
        <span className="n">Off rk</span>
        <span className="n">Def EPA</span>
        <span className="n">Def SR%</span>
        <span className="n">Def rk</span>
        <span className="n">Plays</span>
      </div>
      {CUTS.map((cut) => {
        const o = find('offense', cut.key)
        const d = find('defense', cut.key)
        if (!o && !d) return null
        const off = epaCell(o?.epa_per_play ?? null)
        const def = epaCell(d?.epa_per_play ?? null, true)
        const params = new URLSearchParams({ team: label, season: String(season), ...cut.params })
        return (
          <Link key={cut.key} className="split-row" to={`/${sport}/plays?${params.toString()}`} title="Open in the play log">
            <span className="tm">{cut.label}</span>
            <span className={`n ${off.cls}`}>{off.text}</span>
            <span className="n">{o?.success_rate == null ? '—' : (o.success_rate * 100).toFixed(0)}</span>
            <span className="n">{o?.situation_rank == null ? '—' : ordinal(o.situation_rank)}</span>
            <span className={`n ${def.cls}`}>{def.text}</span>
            <span className="n">{d?.success_rate == null ? '—' : (d.success_rate * 100).toFixed(0)}</span>
            <span className="n">{d?.situation_rank == null ? '—' : ordinal(d.situation_rank)}</span>
            <span className="n">{fmt(o?.plays ?? null)}</span>
          </Link>
        )
      })}
    </div>
  )
}

/* ---- roster ---- */

const ROSTER_ORDER = ['QB', 'RB', 'WR', 'TE']

function RosterTable({ rows, sport, season, seasonType }: { rows: LeadersRow[]; sport: string; season: number; seasonType: string }) {
  if (rows.length === 0) return <p className="hint">No box scores yet.</p>
  const sorted = [...rows].sort((a, b) => {
    const ga = ROSTER_ORDER.indexOf(a.position ?? ''),
      gb = ROSTER_ORDER.indexOf(b.position ?? '')
    return (ga === -1 ? 9 : ga) - (gb === -1 ? 9 : gb) || (b.ppr_points ?? 0) - (a.ppr_points ?? 0)
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
        <span className="n">PPR</span>
        <span className="n">PPR rank</span>
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
              {first ? (first.pct ? pct(r[first.key] as number | null, first.digits ?? 1) : fmt(r[first.key] as number | null, first.digits ?? 0)) : ''}
              <small> {first?.label}</small>
            </span>
            <span className="n">
              {second ? (second.pct ? pct(r[second.key] as number | null, second.digits ?? 1) : fmt(r[second.key] as number | null, second.digits ?? 0)) : ''}
              <small> {second?.label}</small>
            </span>
            <span className="n">{fmt(r.ppr_points, 1)}</span>
            <span className="n">
              {ordinal(r.rank_ppr_points)}
              <small> of {r.players_at_position}</small>
            </span>
          </Link>
        )
      })}
    </div>
  )
}
