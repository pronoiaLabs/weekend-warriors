import { Link, useParams, useSearchParams } from 'react-router-dom'
import { fetchPlayer, fetchPlayerProps, fetchPlayerUsage } from '../../api/sports/client.ts'
import type {
  LeadersRow,
  PlayerPayload,
  PlayerProfileRow,
  PlayerStatRow,
  PlayerUsageRow,
  PlayerWeekRow,
} from '../../api/sports/types.ts'
import Avatar from '../../components/sports/Avatar.tsx'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import Crumbs from '../../components/sports/Crumbs.tsx'
import TeamLogo from '../../components/sports/TeamLogo.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBack } from '../../hooks/useBack.ts'
import { useBranding, teamAccent } from '../../hooks/useBranding.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt, ordinal, pct, signed, tone } from '../../lib/format.ts'
import { CHART_STATS, WEEK_COLS, groupOf, type Group } from '../../lib/positions.ts'

export default function Player() {
  return (
    <CapabilityGate cap="player_leaders">
      <PlayerPage />
    </CapabilityGate>
  )
}

/** The confirmation screen: the pond said this player might be live; this page
    says whether the pattern is real — is the usage stable, does the situational
    profile match, has the market historically underpriced him. */
function PlayerPage() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const { playerKey = '' } = useParams<{ playerKey: string }>()
  const [search, setSearch] = useSearchParams()
  const branding = useBranding(sport)

  const seasonParam = search.get('season')
  const season = seasonParam ? Number(seasonParam) : undefined
  const seasonType = search.get('season_type') ?? undefined
  const statParam = search.get('stat')

  const res = useApi(
    (signal) => fetchPlayer(sport, playerKey, { season, season_type: seasonType }, signal),
    [sport, playerKey, season, seasonType],
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
  const p = data?.player
  const leadersHref = `/${sport}/players${
    data
      ? `?season=${data.season}&season_type=${encodeURIComponent(data.season_type_name)}${p?.position && p.position !== 'WR' ? `&position=${p.position}` : ''}`
      : ''
  }`
  const back = useBack(leadersHref)

  if (!data || !p) {
    return (
      <div className="page page-player">
        <div className="crumb-row">
          <Crumbs items={[{ label: 'Players', to: leadersHref }, { label: res.error ? 'No such player' : '...' }]} />
          <button type="button" className="back" onClick={back}>
            <span aria-hidden="true">←</span> Back to players
          </button>
        </div>
        <div className="page-head">
          <h1>{res.error ? 'No such player' : 'Loading...'}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a player from the <Link to={leadersHref}>finder</Link>.
            </p>
          )}
        </div>
      </div>
    )
  }

  const profile = data.profile
  const group = groupOf(p.position)
  const stats = CHART_STATS[group]
  const stat = stats.some((s) => s.key === statParam) ? statParam! : stats[0]!.key
  const series = data.stats.filter((s) => s.stat_key === stat).sort((a, b) => a.game_date.localeCompare(b.game_date))
  const seasons: number[] = []
  for (const s of data.seasons) if (!seasons.includes(s.season)) seasons.push(s.season)
  seasons.sort((a, b) => b - a)
  const brand = branding.get(profile?.team_key ?? p.team_key ?? '')
  const accent = teamAccent(brand)
  const hasUsage = caps?.capabilities.includes('player_situation_usage') ?? false
  const hasProps = caps?.capabilities.includes('game_prop_board') ?? false
  const logHref = (week?: number) =>
    `/${sport}/plays?player_key=${p.player_key}&season=${data.season}${week !== undefined ? `&week=${week}` : ''}`

  return (
    <div className="page page-player">
      <div className="crumb-row">
        <Crumbs items={[{ label: 'Players', to: leadersHref }, { label: p.player_name }]} />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back to players
        </button>
      </div>

      {/* zone 1 · identity: who he is, where he stands, what's next */}
      <header
        className="team-head player-head"
        data-tilt=""
        style={accent ? ({ '--team': accent } as React.CSSProperties) : undefined}
      >
        <span className="team-bar" aria-hidden="true" />
        <div className="who">
          <div className="who-row">
            <Avatar name={p.player_name} headshotUrl={profile?.headshot_url ?? p.headshot_url} size="xl" />
            <div className="ident">
              <span className="kick">
                <TeamLogo teamKey={profile?.team_key ?? p.team_key} label={null} branding={branding} size="sm" />
                {profile?.team_name ?? p.team_name ?? 'no team'} · {p.position_name ?? p.position}
              </span>
              <h1>
                {p.player_name}
                {profile?.jersey_number && <span className="jersey">#{profile.jersey_number}</span>}
              </h1>
              <div className="bio-strip">
                {profile?.age !== null && profile?.age !== undefined && (
                  <span>
                    Age <b>{profile.age}</b>
                  </span>
                )}
                {profile?.height_inches != null && profile?.weight_lbs != null && (
                  <span>
                    <b>{feet(profile.height_inches)}</b> · <b>{profile.weight_lbs} lb</b>
                  </span>
                )}
                {profile?.college_display && (
                  <span>
                    College <b>{profile.college_display}</b>
                  </span>
                )}
                <span>
                  Draft{' '}
                  <b>
                    {profile?.draft_year
                      ? `${profile.draft_year} · Rd ${profile.draft_round} · Pk ${profile.draft_pick}`
                      : 'undrafted'}
                  </b>
                </span>
                {profile?.seasons_experience != null && profile.seasons_experience > 0 && (
                  <span>
                    <b>{ordinal(profile.seasons_experience)}</b> season
                  </span>
                )}
              </div>
              <div className="head-badges">
                <StatusBadge profile={profile} />
                {profile?.next_game_key && (
                  <Link
                    className="next-chip"
                    to={`/${sport}/games/${profile.next_game_key}`}
                    title={`${profile.next_season_type_name ?? ''} week ${profile.next_week ?? ''}`.trim()}
                  >
                    <TeamLogo teamKey={profile.next_opponent_team_key} label={null} branding={branding} size="sm" />
                    Next · {profile.next_is_home ? 'vs' : '@'} {profile.next_opponent_label} ·{' '}
                    {kickShort(profile.next_game_datetime_et)}
                  </Link>
                )}
              </div>
            </div>
          </div>
        </div>
        <div className="season-side">
          {brand?.wordmark_url && <img className="wordmark" src={brand.wordmark_url} alt="" loading="lazy" />}
          <div className="line-strip three">
            {headline(group, p).map((s) => (
              <Stat key={s.l} v={s.v} l={s.l} />
            ))}
          </div>
        </div>
      </header>

      <div className="filters">
        <Chips
          label="Season"
          items={seasons.map((s) => ({ id: String(s), label: String(s) }))}
          active={String(data.season)}
          onPick={(id) => set({ season: id, season_type: undefined })}
        />
        <Chips
          label="Season type"
          items={data.season_types.map((s) => ({ id: s, label: s }))}
          active={data.season_type_name}
          onPick={(id) => set({ season_type: id })}
        />
      </div>

      {/* zone 2 · the game log */}
      <TileFrame
        title={`Game log · ${data.season}`}
        meta={`${data.season_type_name} · rows open the play log`}
        className="table-tile gamelog"
      >
        <GameLog weeks={data.weeks} group={group} logHref={logHref} branding={branding} />
      </TileFrame>

      {/* zones 3 + 4 · form and where the work comes from, side by side */}
      <div className="cols-detail">
        <TileFrame
          title="Week by week"
          meta={`Dashed line · ${short(data.season - 1)} avg`}
          className="chart-tile"
          caption="Bars are the game (the number above each is its value); the dashed line is his per-game average the season before, same season type; a tick marks the same week that season; the thin path is the trailing three-game average."
        >
          <div className="filters chart-filters">
            <Chips
              label="Stat"
              items={stats.map((s) => ({ id: s.key, label: s.label }))}
              active={stat}
              onPick={(id) => set({ stat: id === stats[0]!.key ? undefined : id })}
            />
          </div>
          <StatChart series={series} isPct={stats.find((s) => s.key === stat)?.pct ?? false} priorLabel={short(data.season - 1)} />
          <YoY data={data} group={group} />
        </TileFrame>
        {hasUsage && (
          <UsageZone
            sport={sport}
            playerKey={playerKey}
            season={data.season}
            seasonTypeName={data.season_type_name}
            position={p.position}
            logHref={logHref()}
          />
        )}
      </div>

      {/* zone 5 · the market on this player */}
      {hasProps && <MarketZone sport={sport} playerKey={playerKey} />}

      <TileFrame title="How this page is built" className="note-tile" query={data.query}>
        <p>
          Four selects on the player's key: his seasons in the leaders mart (the career rows behind the
          Season chips), the profile header row, his games in the chosen season, and the long stat rows
          whose trailing and prior-season columns feed the chart — the year-over-year comparison is a mart
          column, comparing the player to himself whichever team he was on. Situational usage and the prop
          history are their own routes: usage aggregates play-by-play targets per situation with a
          qualified league baseline, and the prop log reads the same mart the game page's prop board does,
          so the two rooms never disagree.
        </p>
      </TileFrame>
    </div>
  )
}

/* ---- zone 1 helpers ---- */

function feet(inches: number): string {
  return `${Math.floor(inches / 12)}'${Math.round(inches % 12)}"`
}

function short(season: number): string {
  return `'${String(season).slice(-2)}`
}

function kickShort(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  return d.toLocaleString('en-US', { weekday: 'short', hour: 'numeric', minute: '2-digit' })
}

function StatusBadge({ profile }: { profile: PlayerProfileRow | null }) {
  if (!profile) return null
  const asOf = profile.news_updated_at ? ` · as of ${new Date(profile.news_updated_at).toLocaleDateString()}` : ''
  if (profile.injury_status) {
    return (
      <span className="badge warn" title={`${profile.injury_notes ?? ''}${asOf}`.trim()}>
        {profile.injury_status}
        {profile.injury_body_part ? ` · ${profile.injury_body_part}` : ''}
      </span>
    )
  }
  if (profile.practice_participation) {
    return (
      <span className="badge ok" title={asOf.slice(3)}>
        {profile.practice_participation}
      </span>
    )
  }
  return <span className="badge ok">No designation</span>
}

function headline(group: Group, p: LeadersRow): { v: string; l: string }[] {
  const pprG = { v: fmt(p.ppr_points_per_game, 1), l: 'PPR / game' }
  if (group === 'QB') {
    return [
      { v: pct(p.completion_pct, 1), l: 'Comp %' },
      { v: fmt(p.passing_yards, 0), l: 'Pass yards' },
      { v: fmt(p.passing_touchdowns, 0), l: 'Pass TD' },
      { v: fmt(p.passing_interceptions, 0), l: 'INT' },
      { v: fmt(p.rushing_yards, 0), l: 'Rush yards' },
      pprG,
    ]
  }
  if (group === 'RB') {
    return [
      { v: fmt(p.rushing_yards, 0), l: 'Rush yards' },
      { v: fmt(p.scrimmage_yards, 0), l: 'Scrimmage' },
      { v: fmt(p.scoring_touchdowns, 0), l: 'TD' },
      { v: pct(p.target_share, 1), l: 'Target share' },
      { v: pct(p.snap_share, 0), l: 'Snap share' },
      pprG,
    ]
  }
  if (group === 'WR' || group === 'TE') {
    return [
      { v: `${fmt(p.receptions, 0)} / ${fmt(p.receiving_targets, 0)}`, l: 'Rec / targets' },
      { v: fmt(p.receiving_yards, 0), l: 'Rec yards' },
      { v: fmt(p.receiving_touchdowns, 0), l: 'Rec TD' },
      { v: pct(p.target_share, 1), l: 'Target share' },
      { v: pct(p.snap_share, 0), l: 'Snap share' },
      pprG,
    ]
  }
  return [
    { v: fmt(p.touches, 0), l: 'Touches' },
    { v: fmt(p.scrimmage_yards, 0), l: 'Scrimmage' },
    { v: fmt(p.scoring_touchdowns, 0), l: 'TD' },
    { v: pct(p.snap_share, 0), l: 'Snap share' },
    { v: String(p.games), l: 'Games' },
    pprG,
  ]
}

function Stat({ v, l, cls }: { v: string; l: string; cls?: string }) {
  return (
    <div className={`stat ${cls ?? ''}`}>
      <span className="v">{v || '—'}</span>
      <span className="l">{l}</span>
    </div>
  )
}

/* ---- zone 2 · game log ---- */

function GameLog({
  weeks,
  group,
  logHref,
  branding,
}: {
  weeks: PlayerWeekRow[]
  group: Group
  logHref: (week?: number) => string
  branding: ReturnType<typeof useBranding>
}) {
  if (weeks.length === 0) return <p className="hint">No games in this season type.</p>
  const cols = WEEK_COLS[group]
  const template = `30px minmax(120px, 1.3fr) 36px repeat(${cols.length}, minmax(46px, .72fr)) 52px`
  return (
    <div className="trows" style={{ '--cols': template } as React.CSSProperties}>
      <div className="trow head">
        <span className="n">Wk</span>
        <span>Opponent</span>
        <span>Res</span>
        {cols.map((c) => (
          <span key={c.key} className="n">
            {c.label}
          </span>
        ))}
        <span />
      </div>
      {weeks.map((w) => (
        <Link
          key={w.game_key}
          className="trow"
          to={logHref(w.week)}
          title={`Watch the week ${w.week} plays`}
        >
          <span className="n rk">{w.week}</span>
          <span className="opp">
            <TeamLogo teamKey={w.opponent_team_key} label={null} branding={branding} size="sm" />
            <b>
              {w.is_home ? 'vs' : '@'} {w.opponent_label}
            </b>
            <small>
              {w.team_points}–{w.opponent_points}
            </small>
          </span>
          <span>
            <i className={`res ${w.team_result ?? ''}`}>{w.team_result ?? '—'}</i>
          </span>
          {cols.map((c) => {
            const v = w[c.key] as number | null
            if (c.signed)
              return (
                <span key={c.key} className={`n ${v !== null ? tone(v) : ''}`}>
                  {v === null ? '–' : signed(v, c.digits ?? 1)}
                </span>
              )
            return (
              <span key={c.key} className="n">
                {c.pct ? pct(v, c.digits ?? 0) : fmt(v, c.digits ?? 0)}
              </span>
            )
          })}
          <span className="go">plays ›</span>
        </Link>
      ))}
    </div>
  )
}

/* ---- zone 3 · the chart ---- */

function StatChart({ series, isPct, priorLabel }: { series: PlayerStatRow[]; isPct: boolean; priorLabel: string }) {
  if (series.length === 0) return <p className="hint">No games in this season type.</p>
  const W = 640
  const H = 200
  const pad = 10
  const base = H - 22
  const top = 26
  const val = (v: number | null) => (v === null ? 0 : v)
  const values = series.flatMap((s) => [val(s.value), s.prior_season_same_week ?? 0, s.prior_season_avg ?? 0, s.trailing3_avg ?? 0])
  const max = Math.max(isPct ? 0.1 : 1, ...values) * 1.05
  const scale = (base - top) / max
  const slot = (W - pad * 2) / series.length
  const bw = Math.max(6, Math.min(26, slot * 0.62))
  const y = (v: number) => base - v * scale
  const prior = series[0]!.prior_season_avg
  const label = (v: number | null) => (v === null ? '–' : isPct ? pct(v, 0) : fmt(v, v >= 100 ? 0 : 1))
  const path = series
    .map((s, i) => `${i === 0 ? 'M' : 'L'} ${(pad + slot * i + slot / 2).toFixed(1)} ${y(s.trailing3_avg ?? val(s.value)).toFixed(1)}`)
    .join(' ')
  return (
    <svg className="stat-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Stat by week with the prior season's average">
      <line x1={pad} x2={W - pad} y1={base} y2={base} className="axis" />
      {prior !== null && prior !== undefined && (
        <>
          <line x1={pad} x2={W - pad} y1={y(prior)} y2={y(prior)} className="prior" />
          <text x={W - pad} y={y(prior) - 4} className="prior-lbl" textAnchor="end">
            {priorLabel} avg {label(prior)}
          </text>
        </>
      )}
      {series.map((s, i) => {
        const x = pad + slot * i + (slot - bw) / 2
        return (
          <g key={s.game_key}>
            <title>{`Week ${s.week}: ${label(s.value)} (trailing 3: ${label(s.trailing3_avg)}, same week last season: ${s.prior_season_same_week === null ? 'did not play' : label(s.prior_season_same_week)})`}</title>
            <rect x={x} y={y(val(s.value))} width={bw} height={Math.max(1, base - y(val(s.value)))} className="bar" />
            <text x={x + bw / 2} y={y(val(s.value)) - 4} className="val" textAnchor="middle">
              {label(s.value)}
            </text>
            {s.prior_season_same_week !== null && (
              <line x1={x - 2} x2={x + bw + 2} y1={y(s.prior_season_same_week)} y2={y(s.prior_season_same_week)} className="tick" />
            )}
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

/** The year-over-year strip: six per-game rates, each with the prior season
    inline. The TD entry compares pace (this average over last season's games)
    rather than a raw total — a client display, not a mart column. */
function YoY({ data, group }: { data: PlayerPayload; group: Group }) {
  const prior = short(data.season - 1)
  const latest = (key: string): PlayerStatRow | undefined => {
    const rows = data.stats.filter((s) => s.stat_key === key)
    return rows[rows.length - 1]
  }
  const rate = (key: string, l: string, isPct = false, digits = 1) => {
    const s = latest(key)
    if (!s) return null
    const v = isPct ? pct(s.season_avg_through, digits) : fmt(s.season_avg_through, digits)
    const cmp = s.prior_season_avg === null ? null : isPct ? pct(s.prior_season_avg, digits) : fmt(s.prior_season_avg, digits)
    return { v, small: cmp ? `· ${prior} ${cmp}` : null, l }
  }
  const pace = (key: string, l: string) => {
    const s = latest(key)
    if (!s) return null
    const v = fmt(s.season_total_through, 0)
    const cmp =
      s.prior_season_avg !== null && s.prior_season_games
        ? `· ${prior} pace ${fmt((s.season_avg_through ?? 0) * s.prior_season_games, 0)} of ${fmt(s.prior_season_avg * s.prior_season_games, 0)}`
        : null
    return { v, small: cmp, l }
  }
  const entries = (
    group === 'QB'
      ? [
          rate('passing_yards', 'Yds / gm'),
          rate('passing_attempts', 'Att / gm'),
          rate('passing_epa', 'EPA / gm'),
          rate('ppr_points', 'PPR / gm'),
          pace('passing_touchdowns', 'Pass TD'),
          pace('passing_interceptions', 'INT'),
        ]
      : group === 'RB'
        ? [
            rate('rushing_yards', 'Yds / gm'),
            rate('touches', 'Touches / gm'),
            rate('target_share', 'Tgt share', true),
            rate('snap_pct', 'Snap %', true, 0),
            rate('ppr_points', 'PPR / gm'),
            pace('scoring_touchdowns', 'TD'),
          ]
        : [
            rate('receiving_yards', 'Yds / gm'),
            rate('receiving_targets', 'Tgt / gm'),
            rate('target_share', 'Tgt share', true),
            rate('air_yards_share', 'Air share', true),
            rate('ppr_points', 'PPR / gm'),
            pace('receiving_touchdowns', 'Rec TD'),
          ]
  ).filter((e): e is NonNullable<typeof e> => e !== null)
  if (entries.length === 0) return null
  return (
    <div className="line-strip yoy">
      {entries.map((e) => (
        <div className="stat" key={e.l}>
          <span className="v">
            {e.v || '—'}
            {e.small && <small> {e.small}</small>}
          </span>
          <span className="l">{e.l}</span>
        </div>
      ))}
    </div>
  )
}

/* ---- zone 4 · where the work comes from ---- */

const GROUP_LABELS: Record<PlayerUsageRow['bucket_type'], string> = {
  down: 'By down',
  field_zone: 'By field zone',
  script: 'By game script',
}
const HOT_EDGE = 0.05

function UsageZone({
  sport,
  playerKey,
  season,
  seasonTypeName,
  position,
  logHref,
}: {
  sport: string
  playerKey: string
  season: number
  seasonTypeName: string
  position: string | null
  logHref: string
}) {
  const res = useApi(
    (signal) => fetchPlayerUsage(sport, playerKey, { season, season_type: seasonTypeName }, signal),
    [sport, playerKey, season, seasonTypeName],
  )
  const rows = res.data?.rows ?? []
  const hot = rows.filter((r) => (r.share_vs_league ?? 0) >= HOT_EDGE && r.targets >= 10)
  const peak = [...hot].sort((a, b) => (b.share_vs_league ?? 0) - (a.share_vs_league ?? 0)).slice(0, 2)
  return (
    <TileFrame
      title="Where the work comes from"
      meta="Target share by situation · cells open the play log"
      className="usage-tile"
    >
      {rows.length === 0 ? (
        <p className="hint">
          {res.error
            ? res.error
            : `No situational usage for the ${seasonTypeName.toLowerCase()} — play-by-play covers the regular season and playoffs only.`}
        </p>
      ) : (
        <div className="usage">
          {(['down', 'field_zone', 'script'] as const).map((bt) => (
            <div className="ugroup" key={bt}>
              <span className="gl">{GROUP_LABELS[bt]}</span>
              <div className="ucells">
                {rows
                  .filter((r) => r.bucket_type === bt)
                  .map((r) => (
                    <Link
                      key={r.bucket}
                      className={`ucell ${hot.includes(r) ? 'hot' : ''}`}
                      to={`${logHref}&${r.bucket_type === 'down' ? 'down_bucket' : r.bucket_type === 'field_zone' ? 'field_zone' : 'script'}=${r.bucket}`}
                      title={`${r.bucket_label}: his plays in the play log`}
                    >
                      <span className="bl">{r.bucket_label}</span>
                      <span className="v">{pct(r.target_share, 0)}</span>
                      <span className="d">
                        {r.targets} tgt · {fmt(r.team_dropbacks, 0)} dropbacks
                      </span>
                    </Link>
                  ))}
              </div>
            </div>
          ))}
          {peak.length > 0 && (
            <p className="pattern">
              <span className="badge ok">The pattern</span> {peak.map((r) => r.bucket_label).join(' + ')}:{' '}
              {peak.map((r) => pct(r.target_share, 0)).join(' and ')} target share — the qualified{' '}
              {position ?? 'position'} average in those spots is{' '}
              {peak.map((r) => pct(r.league_pos_avg_share, 0)).join(' / ')}.
            </p>
          )}
        </div>
      )}
    </TileFrame>
  )
}

/* ---- zone 5 · the market on this player ---- */

const BOOK_SHORT: Record<string, string> = {
  draftkings: 'DK',
  fanduel: 'FD',
  betmgm: 'MGM',
  caesars: 'CZR',
  kalshi: 'KAL',
}

function MarketZone({ sport, playerKey }: { sport: string; playerKey: string }) {
  // the market zone is always "now": it reads the current season's props
  // regardless of which historical season the log above is showing
  const res = useApi((signal) => fetchPlayerProps(sport, playerKey, {}, signal), [sport, playerKey])
  const d = res.data
  if (!d) return null
  const book = d.vendor ? (BOOK_SHORT[d.vendor] ?? d.vendor.toUpperCase()) : '—'
  const now = d.current[0]
  const overs = d.history.filter((r) => r.outcome === 'over').length
  const unders = d.history.filter((r) => r.outcome === 'under').length
  const statName = d.history[0]?.stat_label ?? d.current[0]?.stat_label ?? d.stat_key?.replace(/_/g, ' ') ?? 'prop'
  return (
    <TileFrame
      title={`The market on this player · ${statName} O/U`}
      meta={`${d.season} · ${d.vendor ?? 'no book'}`}
      className="market-player-tile"
    >
      {d.history.length === 0 && d.current.length === 0 ? (
        <p className="hint">
          No {statName} line at {d.vendor ?? 'the default book'} for {d.season}. The odds feed starts in
          2026, and books post lines only for upcoming weeks.
        </p>
      ) : (
        <>
          <div className="market-now">
            <Stat v={book} l="Book" />
            <Stat v={now ? fmt(now.line_value, 1) : '—'} l={now ? `Wk ${now.week} line` : 'No open line'} />
            <Stat v={now && now.projection_value !== null ? fmt(now.projection_value, 1) : '—'} l="Projection" />
            <Stat
              v={now && now.projection_vs_line !== null ? signed(now.projection_vs_line, 1) : '—'}
              l="Proj − line"
              cls={now ? tone(now.projection_vs_line) : undefined}
            />
            <Stat
              v={d.history.length ? `${overs}–${unders} O` : '—'}
              l="Season O/U"
              cls={overs > unders ? 'pos' : overs < unders ? 'neg' : undefined}
            />
          </div>
          {d.history.length > 0 && (
            <div className="trows proplog" style={{ '--cols': '30px minmax(96px, 1.2fr) repeat(3, minmax(52px, .8fr)) 60px' } as React.CSSProperties}>
              <div className="trow head">
                <span className="n">Wk</span>
                <span>Opponent</span>
                <span className="n">Close</span>
                <span className="n">Actual</span>
                <span className="n">Diff</span>
                <span className="n">Hit</span>
              </div>
              {d.history.map((r) => {
                const diff = r.actual_value !== null && r.line_value !== null ? r.actual_value - r.line_value : null
                return (
                  <Link
                    key={r.app_game_prop_board_key}
                    className="trow"
                    to={`/${sport}/markets/${r.game_key}`}
                    title={`Week ${r.week} line history`}
                  >
                    <span className="n rk">{r.week}</span>
                    <span className="tm">
                      <b>
                        {r.is_home ? 'vs' : '@'} {r.opponent_label}
                      </b>
                    </span>
                    <span className="n">{fmt(r.line_value, 1)}</span>
                    <span className="n sorted">{fmt(r.actual_value, 1)}</span>
                    <span className={`n ${diff !== null ? tone(diff) : ''}`}>{diff === null ? '–' : signed(diff, 1)}</span>
                    <span className="n">
                      {r.outcome === 'over' ? (
                        <span className="hit O">Over</span>
                      ) : r.outcome === 'under' ? (
                        <span className="hit U">Under</span>
                      ) : (
                        <span className="hit">{r.outcome ?? '–'}</span>
                      )}
                    </span>
                  </Link>
                )
              })}
            </div>
          )}
          <p className="hint">
            Closing lines are the last pre-kickoff snapshot; a projection rides along where Sleeper had one
            before kickoff. <Link to={`/${sport}/markets`}>Full line history →</Link>
          </p>
        </>
      )}
    </TileFrame>
  )
}
