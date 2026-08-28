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
          <div className="grid pulse-grid">
            <div className="pulse-col">
              <NewsFeed rows={data.news} days={data.days} sport={sport} branding={branding} />
              <MarketMovers data={data} sport={sport} branding={branding} />
            </div>
            <div className="pulse-col">
              <StatusBoard rows={data.status} sport={sport} />
              <TrendingList rows={data.trending} sport={sport} />
            </div>
          </div>
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

function NewsFeed({
  rows,
  days,
  sport,
  branding,
}: {
  rows: MentionRow[]
  days: number
  sport: string
  branding: Branding
}) {
  // injury-tagged first, newest first within each — the wireframe's ordering.
  // The feed caps what it renders: a 48h window can be hundreds of mentions,
  // and the home page is a digest; the News page is the full feed.
  const ordered = [...rows]
    .sort((a, b) => {
      const ai = a.context === 'injury' ? 0 : 1
      const bi = b.context === 'injury' ? 0 : 1
      return ai - bi || b.published_at.localeCompare(a.published_at)
    })
    .slice(0, 80)
  const asOf = new Date().toISOString()
  return (
    <TileFrame title="Around the league" meta={`injury-tagged first · last ${days * 24}h`} className="news-tile">
      {ordered.length === 0 ? (
        <p className="hint">Quiet window — no mentions in the last {days * 24} hours.</p>
      ) : (
        <div className="mentions vfit">
          {ordered.map((m) => (
            <div key={m.mention_key} className="mention pulse">
              <div className="who">
                {m.player_key ? (
                  <Link to={`/${sport}/players/${m.player_key}`}>
                    <Avatar name={m.player_name ?? '?'} headshotUrl={m.headshot_url} sleeperPlayerId={m.sleeper_player_id} />
                  </Link>
                ) : (
                  <Avatar name={m.player_name ?? m.player_name_in_article ?? '?'} />
                )}
                <span className="id">
                  {m.player_key ? (
                    <Link to={`/${sport}/players/${m.player_key}`}>
                      <b>{m.player_name}</b>
                    </Link>
                  ) : (
                    <b>{m.player_name ?? m.player_name_in_article}</b>
                  )}
                  <small>
                    {[m.position, m.team_label].filter(Boolean).join(' · ') || '—'}
                  </small>
                </span>
              </div>
              <div className="what">
                <span>
                  {m.context && <span className={`flag topic ${m.context}`}>{m.context}</span>}
                  {m.url ? (
                    <a className="headline" href={m.url} target="_blank" rel="noreferrer">
                      {m.headline}
                    </a>
                  ) : (
                    <span className="headline">{m.headline}</span>
                  )}
                </span>
                <span className="src">
                  <b>{m.feed}</b> · {agoLabel(m.published_at, asOf)}
                </span>
              </div>
              <div className="next">
                {m.next_game_key ? (
                  <Link to={`/${sport}/games/${m.next_game_key}`}>
                    <TeamLogo teamKey={m.team_key} label={m.team_label} branding={branding} size="sm" />{' '}
                    <b>
                      {m.team_label} {m.next_game_is_home ? 'vs' : 'at'} {m.next_opponent_label}
                    </b>
                    <small>{m.next_game_datetime_et ? `${kickoffDay(m.next_game_datetime_et)} ${kickoffTime(m.next_game_datetime_et)} ET` : ''}</small>
                  </Link>
                ) : (
                  <small>no game scheduled</small>
                )}
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
        <>
          {games.length > 0 && <p className="mv-sub">Games — spread &amp; total</p>}
          {games.map((m) => (
            <MoverRowView key={m.app_market_movers_key} m={m} sport={sport} branding={branding} />
          ))}
          {props.length > 0 && <p className="mv-sub">Props — player lines</p>}
          {props.map((m) => (
            <MoverRowView key={m.app_market_movers_key} m={m} sport={sport} branding={branding} />
          ))}
        </>
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
  // the rail is a digest: the hardest designations, not the whole league
  const shown = rows.slice(0, 12)
  return (
    <TileFrame title="Status board" meta={`designations · practice W/T/F${rows.length > shown.length ? ` · top ${shown.length} of ${rows.length}` : ''}`}>
      {rows.length === 0 ? (
        <p className="hint">Nobody carries a designation right now.</p>
      ) : (
        shown.map((s) => (
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
        ))
      )}
    </TileFrame>
  )
}

function TrendingList({ rows, sport }: { rows: TrendingRow[]; sport: string }) {
  const hours = rows[0]?.lookback_hours ?? 24
  // top of each board only; the rail is a digest, not the full top-100s
  const shown = [
    ...rows.filter((t) => t.direction === 'add').slice(0, 6),
    ...rows.filter((t) => t.direction === 'drop').slice(0, 6),
  ]
  return (
    <TileFrame title="Trending" meta={`Sleeper · adds & drops · ${hours}h`}>
      {rows.length === 0 ? (
        <p className="hint">No trending board captured yet.</p>
      ) : (
        shown.map((t) => (
          <Link key={t.app_trending_players_key} className="trend-row" to={`/${sport}/players/${t.player_key}`}>
            <Avatar name={t.player_name} headshotUrl={t.headshot_url} sleeperPlayerId={t.sleeper_player_id} size="sm" />
            <span className="id">
              <b>{t.player_name}</b>
              <small>{[t.position, t.team_label ?? '—'].filter(Boolean).join(' · ')}</small>
            </span>
            <span className="nxt">
              {t.next_game_key ? `${t.next_game_is_home ? 'vs' : 'at'} ${t.next_opponent_label}` : '—'}
              <small>{t.next_game_datetime_et ? `${kickoffDay(t.next_game_datetime_et)} ${kickoffTime(t.next_game_datetime_et)}` : ''}</small>
            </span>
            <span className={`badge ${t.direction === 'add' ? 'pos' : 'neg'}`}>
              {t.direction === 'add' ? '▲ +' : '▼ −'}
              {Intl.NumberFormat('en-US', { notation: 'compact' }).format(t.move_count_24h)}
            </span>
          </Link>
        ))
      )}
    </TileFrame>
  )
}
