import { Link, useSearchParams } from 'react-router-dom'
import { fetchPulse } from '../../api/sports/client.ts'
import type {
  MentionRow,
  MoverRow,
  PulsePayload,
  SlateRow,
  StatusRow,
  TrendingRow,
} from '../../api/sports/types.ts'
import Avatar from '../../components/sports/Avatar.tsx'
import TeamLogo from '../../components/sports/TeamLogo.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import type { BrandingRow } from '../../api/sports/types.ts'
import { useBranding } from '../../hooks/useBranding.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { boardPath, useView } from '../../state/view.tsx'

type Branding = Map<string, BrandingRow>

/** The Pulse: the home screen. One composite fetch; five zones; every row is a
    door into a game, a player or a market. Mirrors the pulse wireframe. */
export default function Pulse() {
  const sport = useSportParam()
  const branding = useBranding(sport)
  const [search] = useSearchParams()
  const daysParam = search.get('days')
  const days = daysParam && Number(daysParam) >= 1 && Number(daysParam) <= 90 ? Number(daysParam) : undefined

  const res = useApi((signal) => fetchPulse(sport, { days }, signal), [sport, days])
  const data = res.data

  return (
    <div className="page page-pulse">
      <div className="page-head">
        <h1>The Pulse</h1>
        <p className="lede">
          {data
            ? "The first minute on the app. What moved around the league since you last looked — who's in, who's out, where the money went — and every row is a door into the film."
            : res.error
              ? res.error
              : 'Taking the pulse...'}
        </p>
      </div>

      {data && (
        <>
          <SlateStrip data={data} sport={sport} branding={branding} />
          <div className="grid pulse-rails">
            <NewsFeed rows={data.news} days={data.days} sport={sport} />
            <StatusBoard rows={data.status} sport={sport} />
            <TrendingList rows={data.trending} sport={sport} />
          </div>
          <MarketMovers data={data} sport={sport} branding={branding} />
          <TileFrame title="How this screen is built" className="note-tile" query={data.query ?? undefined}>
            <p>
              One fetch composes five known-column selects: the week's slate, the news window, the status
              board (official designations for each team's next game plus live status changes between
              filings), Sleeper's latest add/drop boards, and the biggest line moves since open at the
              chosen book. Nothing here is a dead end — a news item opens the player it names, a status row
              opens the game it matters for, a mover opens the market that repriced.
            </p>
          </TileFrame>
        </>
      )}
    </div>
  )
}

function kickoffDay(iso: string): string {
  return new Date(iso).toLocaleDateString('en-US', { weekday: 'short' }).toUpperCase()
}

function kickoffTime(iso: string): string {
  const [, time] = iso.split('T')
  if (!time) return ''
  const [h, m] = time.split(':').map(Number)
  const hour12 = ((h + 11) % 12) + 1
  return `${hour12}:${String(m).padStart(2, '0')}${h >= 12 ? 'p' : 'a'}`
}

function lineLabel(g: SlateRow): string {
  if (g.home_spread === null || g.home_spread === undefined) return '—'
  const homeFav = g.home_spread <= 0
  const team = homeFav ? g.home_team_label : g.away_team_label
  const num = homeFav ? g.home_spread : -g.home_spread
  return `${team} ${num > 0 ? '+' : '−'}${Math.abs(num)}`
}

function SlateStrip({ data, sport, branding }: { data: PulsePayload; sport: string; branding: Branding }) {
  const { view } = useView()
  // the marquee: the biggest total on the board (the wireframe rings SNF/MNF)
  const maxTotal = Math.max(...data.slate.map((g) => g.total_line ?? 0))
  return (
    <div className="strip-wrap">
      <div className="strip-head">
        <span className="zl">
          This week · {data.season_type_name} week {data.week}
          {data.vendor ? ` · ${data.vendor}` : ''}
        </span>
        <Link to={boardPath(sport, view)}>Full board →</Link>
      </div>
      <div className="strip">
        {data.slate.map((g) => {
          const marquee = g.total_line !== null && g.total_line === maxTotal
          return (
            <Link key={g.game_key} className={`scard${marquee ? ' marquee' : ''}`} to={`/${sport}/games/${g.game_key}`}>
              <span className="slot">
                <span className="day">{kickoffDay(g.game_date)}</span>
                <span>{kickoffTime(g.game_datetime_et)} ET</span>
              </span>
              <span className="vs">
                <TeamLogo teamKey={g.away_team_key} label={g.away_team_label} branding={branding} />
                <span className="ab">{g.away_team_label}</span>
                <span className="at-sm">at</span>
                <TeamLogo teamKey={g.home_team_key} label={g.home_team_label} branding={branding} />
                <span className="ab">{g.home_team_label}</span>
              </span>
              <span className="nums">
                <span className="ln">
                  <span className="v">{lineLabel(g)}</span>
                  <span className="l">Line</span>
                </span>
                <span className="ln">
                  <span className="v">{g.total_line ?? '—'}</span>
                  <span className="l">Total</span>
                </span>
              </span>
            </Link>
          )
        })}
      </div>
    </div>
  )
}

function agoLabel(publishedAt: string, asOf: string): string {
  const hours = Math.max(0, Math.round((Date.parse(asOf) - Date.parse(publishedAt)) / 3.6e6))
  if (hours < 1) return 'now'
  if (hours < 24) return `${hours}h ago`
  return `${Math.round(hours / 24)}d ago`
}

// A mention row is one player in one article; the home feed reads at the
// article grain. The pill is the strongest context any mention carries, so an
// injury story tags injury even when it also names healthy players.
const CONTEXT_RANK: Record<string, number> = { injury: 0, suspension: 1, transaction: 2, lineup: 3, other: 4 }

function contextRank(c: string | null): number {
  return c !== null && c in CONTEXT_RANK ? CONTEXT_RANK[c] : 5
}

type Article = {
  key: string
  headline: string | null
  url: string | null
  feed: string
  published_at: string
  context: string | null
  players: { player_key: string; player_name: string; headshot_url: string | null; sleeper_player_id: string | null }[]
}

function toArticles(rows: MentionRow[]): Article[] {
  const byKey = new Map<string, Article>()
  for (const m of rows) {
    const key = m.article_key
    const found = byKey.get(key)
    const a: Article = found ?? {
      key,
      headline: m.headline,
      url: m.url,
      feed: m.feed,
      published_at: m.published_at,
      context: m.context,
      players: [],
    }
    if (!found) byKey.set(key, a)
    if (contextRank(m.context) < contextRank(a.context)) a.context = m.context
    if (m.published_at > a.published_at) a.published_at = m.published_at
    if (m.player_key && !a.players.some((p) => p.player_key === m.player_key)) {
      a.players.push({
        player_key: m.player_key,
        player_name: m.player_name ?? m.player_name_in_article ?? '?',
        headshot_url: m.headshot_url,
        sleeper_player_id: m.sleeper_player_id,
      })
    }
  }
  return [...byKey.values()].sort((a, b) => {
    const ai = a.context === 'injury' ? 0 : 1
    const bi = b.context === 'injury' ? 0 : 1
    return ai - bi || b.published_at.localeCompare(a.published_at)
  })
}

function NewsFeed({ rows, days, sport }: { rows: MentionRow[]; days: number; sport: string }) {
  // injury-tagged first, newest first within each — the wireframe's ordering,
  // applied at the article grain. The cap is a safety net; a 48h window runs
  // well under it once mentions collapse to stories.
  const articles = toArticles(rows).slice(0, 80)
  const asOf = new Date().toISOString()
  return (
    <TileFrame title="Around the league" meta={`last ${days * 24}h · ${articles.length} stories`}>
      {articles.length === 0 ? (
        <p className="hint">Quiet window — no mentions in the last {days * 24} hours.</p>
      ) : (
        <div className="rail-scroll">
          {articles.map((a) => (
            <div key={a.key} className="news-article">
              <span className="avs">
                {a.players.slice(0, 3).map((p) => (
                  <Link key={p.player_key} to={`/${sport}/players/${p.player_key}`} title={p.player_name}>
                    <Avatar name={p.player_name} headshotUrl={p.headshot_url} sleeperPlayerId={p.sleeper_player_id} size="sm" />
                  </Link>
                ))}
                {a.players.length > 3 && <span className="more">+{a.players.length - 3}</span>}
              </span>
              <div className="what">
                <span>
                  {a.context && <span className={`flag topic ${a.context}`}>{a.context}</span>}
                  {a.url ? (
                    <a className="headline" href={a.url} target="_blank" rel="noreferrer">
                      {a.headline}
                    </a>
                  ) : (
                    <span className="headline">{a.headline}</span>
                  )}
                </span>
                <span className="src">
                  <b>{a.feed}</b> · {agoLabel(a.published_at, asOf)}
                  {a.players.length > 0 && <> · {a.players.map((p) => p.player_name).join(', ')}</>}
                </span>
              </div>
            </div>
          ))}
        </div>
      )}
    </TileFrame>
  )
}

function fmtLine(v: number): string {
  return v > 0 ? `+${v}` : `${v}`
}

function MoverRowView({ m, sport, branding }: { m: MoverRow; sport: string; branding: Branding }) {
  const dir = m.delta > 0 ? 'pos' : 'neg'
  return (
    <Link className="mv-row" to={`/${sport}/markets/${m.game_key}`}>
      <span className="mv-what">
        {m.kind === 'game' ? (
          <>
            <TeamLogo teamKey={m.away_team_key} label={m.away_team_label} branding={branding} size="sm" />
            <TeamLogo teamKey={m.home_team_key} label={m.home_team_label} branding={branding} size="sm" />
            <span className="id">
              <b>
                {m.away_team_label} @ {m.home_team_label}
              </b>
              <small>{m.market === 'spread' ? 'Spread (home)' : 'Total'}</small>
            </span>
          </>
        ) : (
          <>
            <Avatar name={m.player_name ?? '?'} headshotUrl={m.headshot_url} size="sm" />
            <span className="id">
              <b>{m.player_name}</b>
              <small>
                {[m.position, m.team_label, m.stat_label].filter(Boolean).join(' · ')}
              </small>
            </span>
          </>
        )}
      </span>
      <span className="mv-path">
        {fmtLine(m.open_line)}
        <span className="arrow">→</span>
        <b>{fmtLine(m.latest_line)}</b>
        <small>{m.vendor} · open → now</small>
      </span>
      <span className={`badge ${dir}`}>{m.delta > 0 ? '▲' : '▼'} {fmtLine(m.delta)}</span>
    </Link>
  )
}

function MarketMovers({ data, sport, branding }: { data: PulsePayload; sport: string; branding: Branding }) {
  const { games, props } = data.movers
  return (
    <TileFrame title="Market movers" meta={`since open${data.vendor ? ` · ${data.vendor}` : ''}`}>
      {games.length === 0 && props.length === 0 ? (
        <p className="hint">No line has moved off its opener this week.</p>
      ) : (
        <div className="mv-cols">
          <div>
            <p className="mv-sub">Games — spread &amp; total</p>
            {games.length === 0 && <p className="hint">No game line has moved.</p>}
            {games.map((m) => (
              <MoverRowView key={m.app_market_movers_key} m={m} sport={sport} branding={branding} />
            ))}
          </div>
          <div>
            <p className="mv-sub">Props — player lines</p>
            {props.length === 0 && <p className="hint">No prop line has moved.</p>}
            {props.map((m) => (
              <MoverRowView key={m.app_market_movers_key} m={m} sport={sport} branding={branding} />
            ))}
          </div>
        </div>
      )}
    </TileFrame>
  )
}

function badgeClass(s: StatusRow): string {
  const label = (s.designation ?? s.live_injury_status ?? '').toLowerCase()
  if (label === 'out' || label === 'ir') return 'out'
  if (label === 'doubtful') return 'neg'
  if (label === 'questionable') return 'q'
  if (label === 'pup' || label === 'sus') return 'acc'
  return 'ok'
}

function Prac({ code }: { code: string | null }) {
  return <i className={code ?? ''}>{code ?? '·'}</i>
}

function StatusBoard({ rows, sport }: { rows: StatusRow[]; sport: string }) {
  return (
    <TileFrame title="Status board" meta={`practice W/T/F · ${rows.length} players`}>
      {rows.length === 0 ? (
        <p className="hint">Nobody carries a designation right now.</p>
      ) : (
        <div className="rail-scroll">
          {rows.map((s) => (
          <div key={s.app_status_board_key} className="srow">
            <div className="top">
              <Link to={`/${sport}/players/${s.player_key}`}>
                <Avatar name={s.player_name} headshotUrl={s.headshot_url} sleeperPlayerId={s.sleeper_player_id} />
              </Link>
              <span className="id">
                <Link to={`/${sport}/players/${s.player_key}`}>
                  <b>{s.player_name}</b>
                </Link>
                <small>
                  {[s.position, s.team_label ?? '—', s.injury ?? s.live_injury_status].filter(Boolean).join(' · ')}
                </small>
              </span>
            </div>
            <div className="tags">
              {s.game_key ? (
                <Link to={`/${sport}/games/${s.game_key}`}>
                  <span className={`badge ${badgeClass(s)}`}>{(s.designation ?? s.live_injury_status ?? '?').toUpperCase()}</span>
                </Link>
              ) : (
                <span className={`badge ${badgeClass(s)}`}>{(s.designation ?? s.live_injury_status ?? '?').toUpperCase()}</span>
              )}
              <span className="prac">
                <Prac code={s.practice_wed} />
                <Prac code={s.practice_thu} />
                <Prac code={s.practice_fri} />
              </span>
            </div>
            {s.ripple_note && (
              <div className="ripple">
                <i>ripple</i> {s.ripple_note}
              </div>
            )}
          </div>
          ))}
        </div>
      )}
    </TileFrame>
  )
}

const compact = (n: number) => Intl.NumberFormat('en-US', { notation: 'compact' }).format(n)

function TrendingList({ rows, sport }: { rows: TrendingRow[]; sport: string }) {
  const hours = rows[0]?.lookback_hours ?? 24
  // One row per player: Sleeper's boards overlap (a player can be heavily
  // added AND dropped in the same window), so the row leads with the dominant
  // direction and keeps the other as a footnote instead of a second row.
  const byPlayer = new Map<string, { primary: TrendingRow; other: TrendingRow | null }>()
  for (const t of rows) {
    const cur = byPlayer.get(t.player_key)
    if (!cur) byPlayer.set(t.player_key, { primary: t, other: null })
    else if (t.move_count_24h > cur.primary.move_count_24h) byPlayer.set(t.player_key, { primary: t, other: cur.primary })
    else byPlayer.set(t.player_key, { primary: cur.primary, other: t })
  }
  const players = [...byPlayer.values()].sort((a, b) => b.primary.move_count_24h - a.primary.move_count_24h)
  return (
    <TileFrame title="Trending" meta={`Sleeper · ${hours}h · ${players.length} players`}>
      {players.length === 0 ? (
        <p className="hint">No trending board captured yet.</p>
      ) : (
        <div className="rail-scroll">
          {players.map(({ primary: t, other }) => (
          <Link key={t.player_key} className="trend-row" to={`/${sport}/players/${t.player_key}`}>
            <Avatar name={t.player_name} headshotUrl={t.headshot_url} sleeperPlayerId={t.sleeper_player_id} size="sm" />
            <span className="id">
              <b>{t.player_name}</b>
              <small>{[t.position, t.team_label ?? '—'].filter(Boolean).join(' · ')}</small>
            </span>
            <span className="nxt">
              {t.next_game_key ? `${t.next_game_is_home ? 'vs' : 'at'} ${t.next_opponent_label}` : '—'}
              <small>{t.next_game_datetime_et ? `${kickoffDay(t.next_game_datetime_et)} ${kickoffTime(t.next_game_datetime_et)}` : ''}</small>
            </span>
            <span className="mvmt">
              <span className={`badge ${t.direction === 'add' ? 'pos' : 'neg'}`}>
                {t.direction === 'add' ? '▲ +' : '▼ −'}
                {compact(t.move_count_24h)}
              </span>
              {other && (
                <small>
                  also {other.direction === 'add' ? '▲' : '▼'} {compact(other.move_count_24h)}
                </small>
              )}
            </span>
          </Link>
          ))}
        </div>
      )}
    </TileFrame>
  )
}
