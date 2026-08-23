import { Link, useSearchParams } from 'react-router-dom'
import { fetchLeaders } from '../../api/sports/client.ts'
import type { LeadersPayload, LeadersRow } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, pct } from '../../lib/format.ts'
import { DEFAULT_SORT, LEADER_COLS, POSITIONS, groupOf, type Col } from '../../lib/positions.ts'

export default function Players() {
  return (
    <CapabilityGate cap="player_leaders">
      <Leaders />
    </CapabilityGate>
  )
}

function Leaders() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const [search, setSearch] = useSearchParams()

  // The URL holds every choice; the API resolves the season and season type
  // when absent. Position defaults to QB here (the API serves every position
  // when none is named, which is the roster's use of the same route).
  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : undefined
  const seasonType = search.get('season_type') ?? undefined
  const position = (search.get('position') ?? 'QB').toUpperCase()
  const group = groupOf(position)
  const cols = LEADER_COLS[group]
  const sortParam = search.get('sort') as keyof LeadersRow | null
  const sort = cols.some((c) => c.rank === sortParam) ? (sortParam as keyof LeadersRow) : DEFAULT_SORT[group]

  const res = useApi(
    (signal) => fetchLeaders(sport, { season, season_type: seasonType, position }, signal),
    [sport, season, seasonType, position],
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
  const rows = data ? [...data.rows].sort((a, b) => (a[sort] as number) - (b[sort] as number) || a.player_name.localeCompare(b.player_name)) : []
  const playerSearch = data ? `?season=${data.season}&season_type=${encodeURIComponent(data.season_type_name)}` : ''

  return (
    <div className="page page-players">
      <div className="page-head">
        <h1>Player leaders</h1>
        <p className="lede">
          {data
            ? `${position} in the ${data.season_type_name.toLowerCase()}, ${label} ${data.season}. Totals from the completed games, ranks within the position across the whole league; this table shows ${data.rows.length} of ${data.rows[0]?.players_at_position ?? 0} ${position}s with a game.`
            : res.error
              ? res.error
              : 'Loading the leaders...'}
        </p>
      </div>

      {data && <Kpis data={data} cols={cols} />}

      <div className="filters">
        {data && (
          <Chips
            label="Season type"
            items={data.season_types.map((t) => ({ id: t, label: t }))}
            active={data.season_type_name}
            onPick={(id) => set({ season_type: id })}
          />
        )}
        <Chips label="Position" items={POSITIONS} active={position} onPick={(id) => set({ position: id === 'QB' ? undefined : id, sort: undefined })} />
        <Chips
          label="Sort"
          items={cols.filter((c) => c.rank).map((c) => ({ id: c.rank as string, label: c.label }))}
          active={sort as string}
          onPick={(id) => set({ sort: id === DEFAULT_SORT[group] ? undefined : id })}
        />
        <span className="hint">Click a player for the season, week by week.</span>
      </div>

      {res.error && !data && (
        <section className="tile">
          <header className="tile-head">
            <h2>Nothing to show</h2>
          </header>
          <p className="hint">{res.error}</p>
        </section>
      )}

      {data && (
        <TileFrame title={`${position} leaders`} meta={`${rows.length} players`} className="table-tile">
          <LeadersTable rows={rows} cols={cols} sort={sort} sport={sport} playerSearch={playerSearch} />
        </TileFrame>
      )}

      <TileFrame title="How this table is built" className="note-tile" query={data?.query}>
        <p>
          Two selects on the leaders mart: the season's season types (to resolve the one in progress when the
          URL names none), then the rows for the season type and position. Totals are sums of the player's
          completed games, per-game rates are sum over games, and each rank column is a window over every
          player at the position in the league, so a rank here means the same thing as on the player's page.
          The team shown is the one from the player's most recent game; a midseason mover shows a count of
          two.
        </p>
      </TileFrame>
    </div>
  )
}

function Kpis({ data, cols }: { data: LeadersPayload; cols: Col[] }) {
  const ranked = cols.filter((c) => c.rank).slice(0, 4)
  if (data.rows.length === 0) return null
  return (
    <div className="kpis four">
      {ranked.map((c) => {
        const top = data.rows.reduce((a, b) => ((b[c.rank!] as number) < (a[c.rank!] as number) ? b : a))
        return (
          <div className="kpi" key={c.key}>
            <span className="l">{c.label} leader</span>
            <span className="v">{cell(top, c)}</span>
            <span className="s">
              {top.player_name}, {top.team_label}
            </span>
          </div>
        )
      })}
    </div>
  )
}

function LeadersTable({
  rows,
  cols,
  sort,
  sport,
  playerSearch,
}: {
  rows: LeadersRow[]
  cols: Col[]
  sort: keyof LeadersRow
  sport: string
  playerSearch: string
}) {
  const template = `28px minmax(150px, 1.8fr) 44px repeat(${cols.length}, minmax(52px, .8fr))`
  return (
    <div className="trows" style={{ '--cols': template } as React.CSSProperties}>
      <div className="trow head">
        <span>#</span>
        <span>Player</span>
        <span className="n">G</span>
        {cols.map((c) => (
          <span key={c.key} className={`n ${c.rank === sort ? 'sorted' : ''}`}>
            {c.label}
          </span>
        ))}
      </div>
      {rows.map((r) => (
        <Link key={r.player_key} className="trow" to={`/${sport}/players/${r.player_key}${playerSearch}`}>
          <span className="rk">{r[sort] as number}</span>
          <span className="tm">
            <b>{r.player_name}</b>
            <small>
              {r.team_label}
              {r.teams_count > 1 ? ` (+${r.teams_count - 1})` : ''}
            </small>
          </span>
          <span className="n">{r.games}</span>
          {cols.map((c) => (
            <span key={c.key} className={`n ${c.rank === sort ? 'sorted' : ''}`}>
              {cell(r, c)}
            </span>
          ))}
        </Link>
      ))}
    </div>
  )
}

function cell(r: LeadersRow, c: Col): string {
  const v = r[c.key] as number | null
  if (c.pct) return pct(v, 1)
  return fmt(v, c.digits ?? 0)
}
