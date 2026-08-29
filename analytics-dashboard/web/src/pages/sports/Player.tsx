import { Link, useParams, useSearchParams } from 'react-router-dom'
import { fetchPlayer } from '../../api/sports/client.ts'
import type { LeadersRow, PlayerStatRow, PlayerWeekRow } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import Crumbs from '../../components/sports/Crumbs.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBack } from '../../hooks/useBack.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { fmt, ordinal, pct, signed, tone } from '../../lib/format.ts'
import { CHART_STATS, LEADER_COLS, WEEK_COLS, groupOf, statLabel, type Group } from '../../lib/positions.ts'

export default function Player() {
  return (
    <CapabilityGate cap="player_leaders">
      <PlayerPage />
    </CapabilityGate>
  )
}

function PlayerPage() {
  const sport = useSportParam()
  const { playerKey = '' } = useParams<{ playerKey: string }>()
  const [search, setSearch] = useSearchParams()

  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : undefined
  const seasonType = search.get('season_type') ?? undefined
  const statParam = search.get('stat')

  const res = useApi((signal) => fetchPlayer(sport, playerKey, { season, season_type: seasonType }, signal), [sport, playerKey, season, seasonType])

  const set = (patch: Record<string, string | undefined>) => {
    const next = new URLSearchParams(search)
    for (const [k, v] of Object.entries(patch)) {
      if (v === undefined || v === '') next.delete(k)
      else next.set(k, v)
    }
    setSearch(next, { replace: true })
  }

  const data = res.data
  const p = data?.player
  // the leaderboard this player belongs to: his position in the season being shown
  const leadersHref = `/${sport}/players${
    data
      ? `?season=${data.season}&season_type=${encodeURIComponent(data.season_type_name)}${p?.position && p.position !== 'QB' ? `&position=${p.position}` : ''}`
      : ''
  }`
  const back = useBack(leadersHref)

  if (!data || !p) {
    return (
      <div className="page page-player">
        <Crumbs items={[{ label: 'Players', to: leadersHref }, { label: res.error ? 'No such player' : '...' }]} />
        <div className="page-head">
          <h1>{res.error ? 'No such player' : 'Loading...'}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a player from the <Link to={leadersHref}>leaders</Link>.
            </p>
          )}
        </div>
      </div>
    )
  }

  const group = groupOf(p.position)
  const stats = CHART_STATS[group]
  const stat = stats.some((s) => s.key === statParam) ? statParam! : stats[0]!.key
  const series = data.stats.filter((s) => s.stat_key === stat).sort((a, b) => a.game_date.localeCompare(b.game_date))
  const seasons: number[] = []
  for (const s of data.seasons) if (!seasons.includes(s.season)) seasons.push(s.season)
  const headline = LEADER_COLS[group].filter((c) => c.rank).slice(0, 4)

  return (
    <div className="page page-player">
      <div className="crumb-row">
        <Crumbs items={[{ label: 'Players', to: leadersHref }, { label: p.player_name }]} />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to leaders
        </button>
      </div>

      <div className="team-head player-head" data-tilt="">
        <div className="ident">
          <span className="kick">
            {p.position_name ?? p.position} · {p.team_name ?? 'no team'} · {p.season_type_name.toLowerCase()} {p.season}
          </span>
          <h1>
            {p.player_name} <span className="at">{p.position}</span>
          </h1>
          <p className="lede">
            {p.games} game{p.games === 1 ? '' : 's'}
            {p.teams_count > 1 ? ` for ${p.teams_count} teams` : ''}, {ordinal(p.rank_fanduel_points)} of {p.players_at_position} {p.position}s in
            FanDuel points, {ordinal(p.rank_fanduel_points_per_game)} per game.
          </p>
        </div>
        <div className="line-strip">
          {headline.map((c) => (
            <Stat
              key={c.key}
              v={c.pct ? pct(p[c.key] as number | null, 1) : fmt(p[c.key] as number | null, c.digits ?? 0)}
              l={`${c.label} · ${ordinal(p[c.rank!] as number)}`}
            />
          ))}
        </div>
      </div>

      <div className="filters">
        <Chips label="Season" items={seasons.map((s) => ({ id: String(s), label: String(s) }))} active={String(data.season)} onPick={(id) => set({ season: id, season_type: undefined })} />
        <Chips
          label="Season type"
          items={data.season_types.map((s) => ({ id: s, label: s }))}
          active={data.season_type_name}
          onPick={(id) => set({ season_type: id })}
        />
      </div>

      <TileFrame
        title={`${statLabel(group, stat)} by game`}
        meta={`${data.season_type_name} ${data.season}`}
        className="chart-tile"
        caption="Bars are the game; the dashed line is his per-game average the season before (same season type); a tick marks what he did in the same week that season. Below the bars: the trailing three-game average."
      >
        <div className="filters chart-filters">
          <Chips label="Stat" items={stats.map((s) => ({ id: s.key, label: s.label }))} active={stat} onPick={(id) => set({ stat: id === stats[0]!.key ? undefined : id })} />
        </div>
        <StatChart series={series} />
        <YoY series={series} />
      </TileFrame>

      <TileFrame title="Season" meta={`${data.weeks.length} games`} className="table-tile">
        <WeeksTable weeks={data.weeks} group={group} sport={sport} />
      </TileFrame>

      <TileFrame title="Career" meta={`${data.seasons.length} season rows`} className="table-tile" caption="Every season and season type with a game. Ranks are within the position for that season type.">
        <CareerTable rows={data.seasons} group={group} current={p} onPick={(s) => set({ season: String(s.season), season_type: s.season_type_name })} />
      </TileFrame>

      <TileFrame title="How this page is built" className="note-tile" query={data.query}>
        <p>
          Three selects on the player's key: every season in the leaders mart (the career table, and where the
          default season comes from), his games in the chosen season, and the long stat rows for that season.
          The long rows carry the trailing three-game average, the season average through each game and the
          prior-season columns, so the year-over-year comparison is a mart column rather than a page
          computation: it compares the player to himself, whichever team he was on.
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

/** Inline SVG: bars per game, a dashed line at the prior-season average, a tick
    at the prior-season same-week value, a thin line through the trailing
    three-game averages. */
function StatChart({ series }: { series: PlayerStatRow[] }) {
  if (series.length === 0) return <p className="hint">No games in this season type.</p>
  const W = 640
  const H = 180
  const pad = 10
  const base = H - 22
  const values = series.flatMap((s) => [s.value ?? 0, s.prior_season_same_week ?? 0, s.prior_season_avg ?? 0, s.trailing3_avg ?? 0])
  const max = Math.max(1, ...values)
  const scale = (base - pad) / max
  const slot = (W - pad * 2) / series.length
  const bw = Math.max(6, Math.min(26, slot * 0.62))
  const y = (v: number) => base - v * scale
  const prior = series[0]!.prior_season_avg
  const path = series
    .map((s, i) => `${i === 0 ? 'M' : 'L'} ${(pad + slot * i + slot / 2).toFixed(1)} ${y(s.trailing3_avg ?? s.value ?? 0).toFixed(1)}`)
    .join(' ')
  return (
    <svg className="stat-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Stat by game">
      <line x1={pad} x2={W - pad} y1={base} y2={base} className="axis" />
      {prior !== null && prior !== undefined && <line x1={pad} x2={W - pad} y1={y(prior)} y2={y(prior)} className="prior" />}
      {series.map((s, i) => {
        const x = pad + slot * i + (slot - bw) / 2
        return (
          <g key={s.game_key}>
            <title>{`Week ${s.week}: ${fmt(s.value, 1)} (trailing 3: ${fmt(s.trailing3_avg, 1)}, same week last season: ${s.prior_season_same_week === null ? 'did not play' : fmt(s.prior_season_same_week, 1)})`}</title>
            <rect x={x} y={y(s.value ?? 0)} width={bw} height={Math.max(1, base - y(s.value ?? 0))} className="bar" />
            {s.prior_season_same_week !== null && <line x1={x - 2} x2={x + bw + 2} y1={y(s.prior_season_same_week)} y2={y(s.prior_season_same_week)} className="tick" />}
            <text x={x + bw / 2} y={H - 4} className="lbl" textAnchor="middle">
              {s.week}
            </text>
          </g>
        )
      })}
      <path d={path} className="trail" />
    </svg>
  )
}

function YoY({ series }: { series: PlayerStatRow[] }) {
  const last = series[series.length - 1]
  if (!last) return null
  const played = series.filter((s) => s.prior_season_same_week !== null).length
  return (
    <div className="line-strip yoy">
      <Stat v={fmt(last.season_avg_through, 1)} l={`Average through ${last.games_through} games`} />
      <Stat v={fmt(last.season_total_through, 0)} l="Season total" />
      <Stat v={last.prior_season_avg === null ? 'n/a' : fmt(last.prior_season_avg, 1)} l={last.prior_season_games ? `Last season's average (${last.prior_season_games} games)` : 'No prior season'} />
      <Stat v={last.avg_vs_prior_season === null ? 'n/a' : signed(last.avg_vs_prior_season, 1)} l="Average vs last season" cls={tone(last.avg_vs_prior_season)} />
      <Stat v={fmt(last.trailing3_avg, 1)} l="Trailing three games" />
      <Stat v={String(played)} l="Same weeks played last season" />
    </div>
  )
}

function WeeksTable({ weeks, group, sport }: { weeks: PlayerWeekRow[]; group: Group; sport: string }) {
  if (weeks.length === 0) return <p className="hint">No games in this season type.</p>
  const cols = WEEK_COLS[group]
  const template = `32px minmax(120px, 1.4fr) minmax(88px, 1fr) repeat(${cols.length}, minmax(46px, .7fr)) minmax(60px, .8fr)`
  return (
    <div className="trows" style={{ '--cols': template } as React.CSSProperties}>
      <div className="trow head">
        <span className="n">Wk</span>
        <span>Opponent</span>
        <span>Result</span>
        {cols.map((c) => (
          <span key={c.key} className="n">
            {c.label}
          </span>
        ))}
        <span className="n">FD to date</span>
      </div>
      {weeks.map((w) => (
        <Link key={w.game_key} className="trow" to={`/${sport}/games/${w.game_key}`}>
          <span className="n rk">{w.week}</span>
          <span className="tm">
            <b>
              {w.is_home ? 'vs' : 'at'} {w.opponent_label}
            </b>
            <small>
              {w.team_label} · {w.game_date}
            </small>
          </span>
          <span className={`tm ${w.team_result === 'W' ? 'pos' : w.team_result === 'L' ? 'neg' : ''}`}>
            <b>
              {w.team_result} {w.team_points}-{w.opponent_points}
            </b>
          </span>
          {cols.map((c) => (
            <span key={c.key} className="n">
              {fmt(w[c.key] as number | null, c.digits ?? 0)}
            </span>
          ))}
          <span className="n">{fmt(w.fanduel_points_to_date, 1)}</span>
        </Link>
      ))}
    </div>
  )
}

function CareerTable({
  rows,
  group,
  current,
  onPick,
}: {
  rows: LeadersRow[]
  group: Group
  current: LeadersRow
  onPick: (row: LeadersRow) => void
}) {
  const cols = LEADER_COLS[group].filter((c) => c.rank)
  const template = `minmax(120px, 1.2fr) minmax(70px, .8fr) 40px repeat(${cols.length}, minmax(60px, .9fr))`
  const ordered = [...rows].sort((a, b) => b.season - a.season || b.season_type - a.season_type)
  return (
    <div className="trows" style={{ '--cols': template } as React.CSSProperties}>
      <div className="trow head">
        <span>Season</span>
        <span>Team</span>
        <span className="n">G</span>
        {cols.map((c) => (
          <span key={c.key} className="n">
            {c.label}
          </span>
        ))}
      </div>
      {ordered.map((r) => (
        <button
          key={r.app_player_leaders_key}
          type="button"
          className={`trow ${r.app_player_leaders_key === current.app_player_leaders_key ? 'current' : ''}`}
          onClick={() => onPick(r)}
        >
          <span className="tm">
            <b>
              {r.season} {r.season_type_name}
            </b>
          </span>
          <span className="tm">
            <b>{r.team_label}</b>
            {r.teams_count > 1 && <small>{r.teams_count} teams</small>}
          </span>
          <span className="n">{r.games}</span>
          {cols.map((c) => (
            <span key={c.key} className="n">
              {c.pct ? pct(r[c.key] as number | null, 1) : fmt(r[c.key] as number | null, c.digits ?? 0)}
              <small> {ordinal(r[c.rank!] as number)}</small>
            </span>
          ))}
        </button>
      ))}
    </div>
  )
}
