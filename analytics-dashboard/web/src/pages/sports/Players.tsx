import { Link, useSearchParams } from 'react-router-dom'
import { fetchLeaders } from '../../api/sports/client.ts'
import type { BrandingRow, LeadersRow } from '../../api/sports/types.ts'
import Avatar from '../../components/sports/Avatar.tsx'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import TeamLogo from '../../components/sports/TeamLogo.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBranding } from '../../hooks/useBranding.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, pct } from '../../lib/format.ts'
import { DEFAULT_SORT, FALLBACK_SORT, LEADER_COLS, POSITIONS, groupOf, type Col } from '../../lib/positions.ts'
import { useView } from '../../state/view.tsx'

export default function Players() {
  return (
    <CapabilityGate cap="player_leaders">
      <Finder />
    </CapabilityGate>
  )
}

/** The finder: cast wide, filter down. Usage sorts (target share, snap %)
    surface the risers a yardage leaderboard hides; the rail names the biggest
    recent target-share jumps with the next matchup. */
function Finder() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const branding = useBranding(sport)
  const [search, setSearch] = useSearchParams()
  const { view, setView } = useView()

  // the URL wins; the shared view fills season and type in when it is silent,
  // so a jump from the slate lands on the same slice
  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : view.season
  const seasonType = search.get('season_type') ?? view.season_type
  const position = (search.get('position') ?? 'WR').toUpperCase()
  const team = search.get('team')?.toUpperCase()
  const group = groupOf(position === 'ALL' ? undefined : position)
  const cols = LEADER_COLS[group]
  const sortParam = search.get('sort') as keyof LeadersRow | null
  const sort = cols.some((c) => c.rank === sortParam) ? (sortParam as keyof LeadersRow) : DEFAULT_SORT[group]

  const res = useApi(
    (signal) =>
      fetchLeaders(
        sport,
        {
          season,
          season_type: seasonType,
          position: position === 'ALL' ? undefined : position,
          team,
        },
        signal,
      ),
    [sport, season, seasonType, position, team],
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

  // sort by the chosen rank; the fallback rank breaks the wall of ties a
  // rank over an uncovered column produces (preseason usage is all NULL)
  const fallback = FALLBACK_SORT[group]
  const sorted = data
    ? [...data.rows].sort(
        (a, b) =>
          (a[sort] as number) - (b[sort] as number) ||
          (a[fallback] as number) - (b[fallback] as number) ||
          a.player_name.localeCompare(b.player_name),
      )
    : []
  // the wireframe's "min 4 games" floor -- only once the season can carry it
  const maxGames = sorted.reduce((m, r) => Math.max(m, r.games), 0)
  const minGames = maxGames >= 8 ? 4 : 1
  const rows = sorted.filter((r) => r.games >= minGames)
  const risers = data
    ? [...data.rows]
        .filter((r) => r.target_share_delta !== null && r.target_share_delta > 0)
        .sort((a, b) => (b.target_share_delta ?? 0) - (a.target_share_delta ?? 0))
        .slice(0, 6)
    : []
  const playerSearch = data ? `?season=${data.season}&season_type=${encodeURIComponent(data.season_type_name)}` : ''
  const teamOptions = [...branding.values()].sort((a, b) => a.team_label.localeCompare(b.team_label))
  const posLabel = position === 'ALL' ? 'All positions' : position

  return (
    <div className="page page-players">
      <div className="page-head">
        <h1>Players</h1>
        <p className="lede">
          {data ? (
            <>
              Cast wide, filter down. The leaderboard sorts by usage — target share, snaps — not just
              yardage, because usage moves before the box score does. Click a row to dig into a player's
              season; {label} {data.season} {data.season_type_name.toLowerCase()}.
            </>
          ) : res.error ? (
            res.error
          ) : (
            'Loading the players...'
          )}
        </p>
      </div>

      <div className="filters">
        {data && data.seasons.length > 1 && (
          <label className="psel-wrap">
            Season
            <select
              className="psel"
              value={data.season}
              onChange={(e) => set({ season: e.target.value })}
            >
              {data.seasons.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
          </label>
        )}
        {data && (
          <Chips
            label="Season type"
            items={data.season_types.map((t) => ({ id: t, label: t }))}
            active={data.season_type_name}
            onPick={(id) => set({ season_type: id })}
          />
        )}
        <Chips
          label="Position"
          items={[...POSITIONS, { id: 'ALL', label: 'All' }]}
          active={position}
          onPick={(id) => set({ position: id === 'WR' ? undefined : id, sort: undefined })}
        />
        <label className="psel-wrap">
          Team
          <select className="psel" value={team ?? ''} onChange={(e) => set({ team: e.target.value || undefined })}>
            <option value="">All teams</option>
            {teamOptions.map((t) => (
              <option key={t.team_key} value={t.team_label}>
                {t.team_label}
              </option>
            ))}
          </select>
        </label>
        <Chips
          label="Sort"
          items={cols.filter((c) => c.rank).map((c) => ({ id: c.rank as string, label: c.label }))}
          active={sort as string}
          onPick={(id) => set({ sort: id === DEFAULT_SORT[group] ? undefined : id })}
        />
        <span className="hint">
          Usage sorts surface risers a yardage leaderboard hides — a 22% target share on a bad day beats a
          fluky 120-yard game.
        </span>
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
        <div className="cols-players">
          <TileFrame
            title={`${posLabel} leaders`}
            meta={`${rows.length} players${minGames > 1 ? ` · min ${minGames} games` : ''}`}
            className="table-tile leaders-tile"
          >
            <LeadersTable
              rows={rows}
              cols={cols}
              sort={sort}
              sport={sport}
              playerSearch={playerSearch}
              branding={branding}
            />
          </TileFrame>
          <TileFrame title="Risers" meta="tgt share · last 3 games" className="risers-tile">
            {risers.length > 0 ? (
              <>
                {risers.map((r) => (
                  <Riser key={r.player_key} r={r} sport={sport} playerSearch={playerSearch} />
                ))}
                <p className="hint">
                  Target share over the last three games vs the weeks before. Usage jumps like these usually
                  show up in the box score a week or two later — this is the fishing hook.
                </p>
              </>
            ) : (
              <p className="hint">
                Risers appear once the season has enough played weeks — at least two games in the recent
                window and two before it, with usage data behind them. There is no usage feed for the
                preseason.
              </p>
            )}
          </TileFrame>
        </div>
      )}

      <TileFrame title="How this table is built" className="note-tile" query={data?.query}>
        <p>
          Two selects on the leaders mart: one thin probe for the seasons and season types it holds, then
          the rows for the chosen slice. Totals are sums of the player's completed games; target share and
          snap share are ratios of sums (never averages of averages); PPR is nflverse's scoring, the
          best-covered feed. Each rank is a window over every player at the position in the league, so a
          rank here means the same thing on the player's page. The riser column compares the average target
          share of the last three played games with the weeks before them, and only speaks when both
          windows hold at least two games with usage data.
        </p>
      </TileFrame>
    </div>
  )
}

function LeadersTable({
  rows,
  cols,
  sort,
  sport,
  playerSearch,
  branding,
}: {
  rows: LeadersRow[]
  cols: Col[]
  sort: keyof LeadersRow
  sport: string
  playerSearch: string
  branding: Map<string, BrandingRow>
}) {
  const template = `28px minmax(190px, 1.9fr) 34px repeat(${cols.length}, minmax(52px, .8fr)) 48px 36px`
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
        <span className="n">Rk</span>
        <span className="n" title="target share, last 3 games vs the weeks before">
          3w
        </span>
      </div>
      {rows.map((r, i) => (
        <Link key={r.player_key} className="trow" to={`/${sport}/players/${r.player_key}${playerSearch}`}>
          <span className="rk">{i + 1}</span>
          <span className="pcell">
            <Avatar name={r.player_name} headshotUrl={r.headshot_url} size="sm" />
            <span className="who">
              <b>{r.player_name}</b>
              <small>
                {r.team_label ?? '—'}
                {r.teams_count > 1 ? ` (+${r.teams_count - 1})` : ''} · {r.position ?? '—'}
              </small>
            </span>
            <TeamLogo teamKey={r.team_key} label={null} branding={branding} size="sm" />
          </span>
          <span className="n">{r.games}</span>
          {cols.map((c) => (
            <span key={c.key} className={`n ${c.rank === sort ? 'sorted' : ''}`}>
              {cell(r, c)}
            </span>
          ))}
          <span className="n">
            {r.ppr_points !== null && r.position ? (
              <span className="posrk">{`${r.position}${r.rank_ppr_points}`}</span>
            ) : (
              '–'
            )}
          </span>
          <span className="n">
            <Trend delta={r.target_share_delta} />
          </span>
        </Link>
      ))}
    </div>
  )
}

function Trend({ delta }: { delta: number | null }) {
  if (delta === null) return <span className="trend">–</span>
  if (delta > 0.01) return <span className="trend pos">▲</span>
  if (delta < -0.01) return <span className="trend neg">▼</span>
  return <span className="trend">–</span>
}

function Riser({ r, sport, playerSearch }: { r: LeadersRow; sport: string; playerSearch: string }) {
  const delta = r.target_share_delta ?? 0
  // rank 1 allows the MOST; the rail speaks stingy-ordering ("27th vs WR")
  const oppRank =
    r.next_opp_allowed_rank !== null && r.next_opp_allowed_teams_ranked !== null
      ? `${ordinal(r.next_opp_allowed_teams_ranked - r.next_opp_allowed_rank + 1)} vs ${r.position}`
      : null
  return (
    <Link className="riser" to={`/${sport}/players/${r.player_key}${playerSearch}`}>
      <Avatar name={r.player_name} headshotUrl={r.headshot_url} size="sm" />
      <span className="who">
        <b>{r.player_name}</b>
        <small>
          {r.team_label ?? '—'}
          {r.next_opponent_label ? ` · ${r.next_is_home ? 'vs' : '@'} ${r.next_opponent_label}` : ''}
          {oppRank ? ` · ${oppRank}` : ''}
        </small>
      </span>
      <span className="delta">
        <span className="badge pos">▲ +{(delta * 100).toFixed(1)} tgt%</span>
        <small>
          {pct(r.target_share_prior, 1)} → {pct(r.target_share_last3, 1)}
        </small>
      </span>
    </Link>
  )
}

function ordinal(n: number): string {
  const s = ['th', 'st', 'nd', 'rd']
  const v = n % 100
  return `${n}${s[(v - 20) % 10] ?? s[v] ?? s[0]}`
}

function cell(r: LeadersRow, c: Col): string {
  const v = r[c.key] as number | null
  if (c.pct) return pct(v, c.digits ?? 1)
  return fmt(v, c.digits ?? 0)
}
