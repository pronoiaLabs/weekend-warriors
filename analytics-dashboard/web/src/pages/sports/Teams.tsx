import { Link, useSearchParams } from 'react-router-dom'
import { fetchStandings } from '../../api/sports/client.ts'
import type { Split, StandingsPayload, StandingsRow } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, signed, tone } from '../../lib/format.ts'

const SPLITS: { id: Split; label: string }[] = [
  { id: 'all', label: 'All games' },
  { id: 'home', label: 'Home' },
  { id: 'away', label: 'Away' },
]

export default function Teams() {
  return (
    <CapabilityGate cap="team_standings">
      <Standings />
    </CapabilityGate>
  )
}

function Standings() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const [search, setSearch] = useSearchParams()

  // The URL holds every choice; the API resolves what is absent (current
  // season, the season type in progress). Split and grouping are page-only.
  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : undefined
  const seasonType = search.get('season_type') ?? undefined
  const splitParam = search.get('split')
  const split: Split = splitParam === 'home' || splitParam === 'away' ? splitParam : 'all'
  const grouped = search.get('group') !== 'league'

  const res = useApi(
    (signal) => fetchStandings(sport, { season, season_type: seasonType, split }, signal),
    [sport, season, seasonType, split],
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
  // the team page should open on the slice being looked at
  const teamSearch = (() => {
    const p = new URLSearchParams()
    if (data) {
      if (season !== undefined) p.set('season', String(season))
      p.set('season_type', data.season_type_name)
    }
    const qs = p.toString()
    return qs ? `?${qs}` : ''
  })()

  return (
    <div className="page page-teams">
      <div className="page-head">
        <h1>Standings</h1>
        <p className="lede">
          {data
            ? `${data.season_type_name}, ${label} ${data.season}, ${SPLITS.find((s) => s.id === data.split)?.label.toLowerCase()}. Ranked by win percentage, then point differential. Records come from the completed games in the facts, so they are live during a season.`
            : res.error
              ? res.error
              : 'Loading the table...'}
        </p>
      </div>

      {data && <Kpis data={data} />}

      <div className="filters">
        {data && (
          <Chips
            label="Season type"
            items={data.season_types.map((t) => ({ id: t, label: t }))}
            active={data.season_type_name}
            onPick={(id) => set({ season_type: id })}
          />
        )}
        <Chips label="Split" items={SPLITS} active={split} onPick={(id) => set({ split: id === 'all' ? undefined : id })} />
        <Chips
          label="Group"
          items={[
            { id: 'division', label: 'By division' },
            { id: 'league', label: 'League' },
          ]}
          active={grouped ? 'division' : 'league'}
          onPick={(id) => set({ group: id === 'division' ? undefined : id })}
        />
        <span className="hint">Click a team for its season.</span>
      </div>

      {res.error && !data && (
        <section className="tile">
          <header className="tile-head">
            <h2>Nothing to show</h2>
          </header>
          <p className="hint">{res.error}</p>
        </section>
      )}

      {data && (grouped ? <Divisions data={data} sport={sport} teamSearch={teamSearch} /> : <League data={data} sport={sport} teamSearch={teamSearch} />)}

      <TileFrame title="How this table is built" className="note-tile" query={data?.query}>
        <p>
          One select on the standings mart for the season, every season type and split at once, filtered
          here to the chips. Each row is the sum of the team's completed games in the split (rates are
          sum over sum, never an average of per-game rates), ranked within the season type and split
          overall, within the conference and within the division. Home and away rows add up to the
          all-games row by construction.
        </p>
      </TileFrame>
    </div>
  )
}

function Kpis({ data }: { data: StandingsPayload }) {
  const rows = data.rows
  if (rows.length === 0) return null
  const best = rows[0]!
  const diff = rows.reduce((a, b) => ((b.point_diff ?? -Infinity) > (a.point_diff ?? -Infinity) ? b : a))
  const ypp = rows.filter((r) => r.yards_per_play !== null)
  const offense = ypp.length ? ypp.reduce((a, b) => (b.yards_per_play! > a.yards_per_play! ? b : a)) : null
  const oypp = rows.filter((r) => r.opp_yards_per_play !== null)
  const defense = oypp.length ? oypp.reduce((a, b) => (b.opp_yards_per_play! < a.opp_yards_per_play! ? b : a)) : null
  return (
    <div className="kpis four">
      <div className="kpi">
        <span className="l">Best record</span>
        <span className="v">{record(best)}</span>
        <span className="s">{best.team_name}</span>
      </div>
      <div className="kpi">
        <span className="l">Best point differential</span>
        <span className="v">{signed(diff.point_diff, 0)}</span>
        <span className="s">
          {diff.team_name}, {signed(diff.point_diff_per_game, 1)} per game
        </span>
      </div>
      <div className="kpi">
        <span className="l">Most yards per play</span>
        <span className="v">{offense ? fmt(offense.yards_per_play, 2) : 'n/a'}</span>
        <span className="s">{offense ? offense.team_name : 'no box scores'}</span>
      </div>
      <div className="kpi">
        <span className="l">Fewest allowed per play</span>
        <span className="v">{defense ? fmt(defense.opp_yards_per_play, 2) : 'n/a'}</span>
        <span className="s">{defense ? defense.team_name : 'no box scores'}</span>
      </div>
    </div>
  )
}

function Divisions({ data, sport, teamSearch }: { data: StandingsPayload; sport: string; teamSearch: string }) {
  const groups: { key: string; conference: string; division: string; rows: StandingsRow[] }[] = []
  for (const r of data.rows) {
    const conference = r.conference ?? 'No conference'
    const division = r.division ?? 'No division'
    const key = `${conference} ${division}`
    let g = groups.find((x) => x.key === key)
    if (!g) {
      g = { key, conference, division, rows: [] }
      groups.push(g)
    }
    g.rows.push(r)
  }
  groups.sort((a, b) => a.key.localeCompare(b.key))
  return (
    <div className="grid cols-divisions">
      {groups.map((g) => (
        <TileFrame key={g.key} title={g.key} meta={`${g.rows.length} teams`} className="stand-tile">
          <Table rows={[...g.rows].sort((a, b) => a.rank_division - b.rank_division)} rankOf={(r) => r.rank_division} sport={sport} teamSearch={teamSearch} />
        </TileFrame>
      ))}
    </div>
  )
}

function League({ data, sport, teamSearch }: { data: StandingsPayload; sport: string; teamSearch: string }) {
  return (
    <TileFrame title="League" meta={`${data.rows.length} teams`} className="stand-tile">
      <Table rows={data.rows} rankOf={(r) => r.rank_overall} sport={sport} teamSearch={teamSearch} />
    </TileFrame>
  )
}

function Table({
  rows,
  rankOf,
  sport,
  teamSearch,
}: {
  rows: StandingsRow[]
  rankOf: (r: StandingsRow) => number
  sport: string
  teamSearch: string
}) {
  return (
    <div className="stand">
      <div className="stand-row head">
        <span>#</span>
        <span>Team</span>
        <span className="n">W-L-T</span>
        <span className="n">Pct</span>
        <span className="n">PF</span>
        <span className="n">PA</span>
        <span className="n">Diff</span>
        <span className="n">YPP</span>
        <span className="n">Opp YPP</span>
        <span className="n">TO</span>
        <span className="n">Last 3</span>
      </div>
      {rows.map((r) => (
        <Link key={r.team_key} className="stand-row" to={`/${sport}/teams/${r.team_label}${teamSearch}`}>
          <span className="rk">{rankOf(r)}</span>
          <span className="tm">
            <b>{r.team_label}</b>
            <small>{r.team_name}</small>
          </span>
          <span className="n">{record(r)}</span>
          <span className="n">{r.win_pct === null ? '' : r.win_pct.toFixed(3).replace(/^0/, '')}</span>
          <span className="n">{fmt(r.points_for)}</span>
          <span className="n">{fmt(r.points_against)}</span>
          <span className={`n ${tone(r.point_diff)}`}>{signed(r.point_diff, 0)}</span>
          <span className="n">{fmt(r.yards_per_play, 2)}</span>
          <span className="n">{fmt(r.opp_yards_per_play, 2)}</span>
          <span className={`n ${tone(r.turnover_margin)}`}>{signed(r.turnover_margin, 0)}</span>
          <span className="n last">
            {(r.last_results ?? []).map((x, i) => (
              <i key={i} className={`res ${x}`}>
                {x}
              </i>
            ))}
          </span>
        </Link>
      ))}
    </div>
  )
}

export function record(r: { wins: number; losses: number; ties: number }): string {
  return r.ties ? `${r.wins}-${r.losses}-${r.ties}` : `${r.wins}-${r.losses}`
}
