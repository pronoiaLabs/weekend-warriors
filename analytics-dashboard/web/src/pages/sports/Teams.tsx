import { Link, useSearchParams } from 'react-router-dom'
import { fetchStandings } from '../../api/sports/client.ts'
import type { BrandingRow, Split, StandingsPayload, StandingsRow } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import TeamLogo from '../../components/sports/TeamLogo.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBranding } from '../../hooks/useBranding.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt } from '../../lib/format.ts'
import { useView } from '../../state/view.tsx'

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

/** The league at a glance: standings carrying the efficiency columns the
    record hides, one division per tile, every row a door to the team page. */
function Standings() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const branding = useBranding(sport)
  const [search, setSearch] = useSearchParams()
  const { view, setView } = useView()

  // the URL wins; the shared view fills season and type in when it is silent
  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : view.season
  const seasonType = search.get('season_type') ?? view.season_type
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
    if ('season' in patch || 'season_type' in patch) {
      setView({
        season: patch.season !== undefined ? Number(patch.season) || undefined : season,
        season_type: 'season_type' in patch ? patch.season_type : seasonType,
        week: undefined,
      })
    }
  }

  const data = res.data
  const label = caps?.label ?? sport.toUpperCase()
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
        <h1>Teams</h1>
        <p className="lede">
          {data ? (
            <>
              The league at a glance, then one team under the glass. Standings carry the efficiency
              columns the record hides — EPA per play, success rate — and the team page is where a matchup
              story starts. {label} {data.season} {data.season_type_name.toLowerCase()},{' '}
              {SPLITS.find((s) => s.id === data.split)?.label.toLowerCase()}.
            </>
          ) : res.error ? (
            res.error
          ) : (
            'Loading the table...'
          )}
        </p>
      </div>

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

      {data && (grouped ? <Divisions data={data} sport={sport} teamSearch={teamSearch} branding={branding} /> : <League data={data} sport={sport} teamSearch={teamSearch} branding={branding} />)}

      <TileFrame title="How this table is built" className="note-tile" query={data?.query}>
        <p>
          One select on the standings mart for the season, every season type and split at once, filtered
          here to the chips. Each row is the sum of the team's completed games in the split (rates are
          sum over sum, never an average of per-game rates), ranked within the season type and split.
          The EPA columns come from play-by-play, so they are honestly empty for the preseason; defensive
          EPA reads inverted — negative is good. Home and away records ride every row of the team-season.
        </p>
      </TileFrame>
    </div>
  )
}

function Divisions({ data, sport, teamSearch, branding }: { data: StandingsPayload; sport: string; teamSearch: string; branding: Map<string, BrandingRow> }) {
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
          <Table rows={[...g.rows].sort((a, b) => a.rank_division - b.rank_division)} rankOf={(r) => r.rank_division} sport={sport} teamSearch={teamSearch} branding={branding} />
        </TileFrame>
      ))}
    </div>
  )
}

function League({ data, sport, teamSearch, branding }: { data: StandingsPayload; sport: string; teamSearch: string; branding: Map<string, BrandingRow> }) {
  return (
    <TileFrame title="League" meta={`${data.rows.length} teams`} className="stand-tile">
      <Table rows={data.rows} rankOf={(r) => r.rank_overall} sport={sport} teamSearch={teamSearch} branding={branding} />
    </TileFrame>
  )
}

/** EPA formatted signed to 2dp with a real minus; green when good, and the
    defensive read is inverted (allowing negative EPA is the good side). */
export function epaCell(v: number | null, defense = false): { text: string; cls: string } {
  if (v === null) return { text: '—', cls: '' }
  const text = (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(2)
  if (v === 0) return { text, cls: '' }
  const good = defense ? v < 0 : v > 0
  return { text, cls: good ? 'pos' : 'neg' }
}

function srCls(v: number | null): string {
  if (v === null) return ''
  return v >= 0.46 ? 'pos' : v <= 0.42 ? 'neg' : ''
}

function Table({
  rows,
  rankOf,
  sport,
  teamSearch,
  branding,
}: {
  rows: StandingsRow[]
  rankOf: (r: StandingsRow) => number
  sport: string
  teamSearch: string
  branding: Map<string, BrandingRow>
}) {
  return (
    <div className="stand">
      <div className="stand-row head">
        <span>#</span>
        <span>Team</span>
        <span className="n">W-L</span>
        <span className="n">PF</span>
        <span className="n">PA</span>
        <span className="n">Off EPA</span>
        <span className="n">Def EPA</span>
        <span className="n">SR%</span>
        <span className="n">Home</span>
        <span className="n">Away</span>
        <span className="n">Last 5</span>
      </div>
      {rows.map((r) => {
        const off = epaCell(r.off_epa_per_play)
        const def = epaCell(r.def_epa_per_play, true)
        return (
          <Link key={r.team_key} className="stand-row" to={`/${sport}/teams/${r.team_label}${teamSearch}`}>
            <span className="rk">{rankOf(r)}</span>
            <span className="tm">
              <TeamLogo teamKey={r.team_key} label={null} branding={branding} size="sm" />
              <b>{branding.get(r.team_key)?.team_nickname ?? r.team_name}</b>
            </span>
            <span className="n">{record(r)}</span>
            <span className="n">{fmt(r.points_for)}</span>
            <span className="n">{fmt(r.points_against)}</span>
            <span className={`n ${off.cls}`}>{off.text}</span>
            <span className={`n ${def.cls}`}>{def.text}</span>
            <span className={`n ${srCls(r.success_rate)}`}>
              {r.success_rate === null ? '—' : (r.success_rate * 100).toFixed(1)}
            </span>
            <span className="n">{r.home_record ?? '—'}</span>
            <span className="n">{r.away_record ?? '—'}</span>
            <span className="n last">
              {[...(r.last_results ?? [])].reverse().map((x, i) => (
                <i key={i} className={`res ${x}`}>
                  {x}
                </i>
              ))}
            </span>
          </Link>
        )
      })}
    </div>
  )
}

export function record(r: { wins: number; losses: number; ties: number }): string {
  return r.ties ? `${r.wins}-${r.losses}-${r.ties}` : `${r.wins}-${r.losses}`
}
