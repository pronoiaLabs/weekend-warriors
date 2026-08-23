import { Link, useSearchParams } from 'react-router-dom'
import { fetchNews } from '../../api/sports/client.ts'
import type { MentionRow, NewsPayload } from '../../api/sports/types.ts'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Chips from '../../components/sports/Chips.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'

const WINDOWS = [3, 7, 14, 30]
const POSITION_GROUPS = ['QB', 'RB', 'WR', 'TE', 'OL', 'DL', 'LB', 'DB', 'ST']

export default function News() {
  return (
    <CapabilityGate cap="news">
      <NewsFeed />
    </CapabilityGate>
  )
}

function NewsFeed() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const [search, setSearch] = useSearchParams()

  // the window and team go to the API; position, feed and resolution are
  // columns on every row, so they filter here
  const daysParam = search.get('days')
  const days = daysParam && WINDOWS.includes(Number(daysParam)) ? Number(daysParam) : undefined
  const team = search.get('team') ?? undefined
  const position = search.get('position') ?? undefined
  const feed = search.get('feed') ?? undefined
  const topic = search.get('topic') ?? undefined
  const resolvedOnly = search.get('resolved') === '1'

  const res = useApi((signal) => fetchNews(sport, { days, team }, signal), [sport, days, team])

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
  const rows = data
    ? data.rows.filter(
        (m) =>
          (!position || groupOfPosition(m) === position) &&
          (!feed || m.feed === feed) &&
          (!topic || m.context === topic) &&
          (!resolvedOnly || m.is_player_resolved),
      )
    : []
  const positions = data ? POSITION_GROUPS.filter((g) => data.rows.some((m) => groupOfPosition(m) === g)) : []
  // the mart's context column is the article's topic (injury, transaction, lineup ...)
  const topics: string[] = []
  if (data) for (const m of data.rows) if (m.context && !topics.includes(m.context)) topics.push(m.context)
  topics.sort()

  return (
    <div className="page page-news">
      <div className="page-head">
        <h1>News</h1>
        <p className="lede">
          {data
            ? `${label} player mentions in the ${data.days} days before ${data.as_of.slice(0, 10)}${data.team ? `, ${data.team}` : ''}. Each mention carries the team's next game, so the question is always "and who does he play next".`
            : res.error
              ? res.error
              : 'Loading the feed...'}
        </p>
      </div>

      {data && <Kpis data={data} shown={rows.length} />}

      <div className="filters">
        <Chips label="Window" items={WINDOWS.map((d) => ({ id: String(d), label: `${d} days` }))} active={String(data?.days ?? days ?? 7)} onPick={(id) => set({ days: id === '7' ? undefined : id })} />
        {data && data.teams.length > 0 && (
          <Chips label="Team" items={[{ id: '', label: 'All teams' }, ...data.teams.map((t) => ({ id: t, label: t }))]} active={team ?? ''} onPick={(id) => set({ team: id || undefined })} />
        )}
      </div>
      <div className="filters">
        {topics.length > 0 && <Chips label="Topic" items={[{ id: '', label: 'Any topic' }, ...topics.map((t) => ({ id: t, label: t }))]} active={topic ?? ''} onPick={(id) => set({ topic: id || undefined })} />}
        {positions.length > 0 && <Chips label="Position" items={[{ id: '', label: 'Any position' }, ...positions.map((p) => ({ id: p, label: p }))]} active={position ?? ''} onPick={(id) => set({ position: id || undefined })} />}
        {data && data.feeds.length > 1 && <Chips label="Feed" items={[{ id: '', label: 'All feeds' }, ...data.feeds.map((f) => ({ id: f, label: f }))]} active={feed ?? ''} onPick={(id) => set({ feed: id || undefined })} />}
        <button type="button" className={`chip ${resolvedOnly ? 'on' : ''}`} aria-pressed={resolvedOnly} onClick={() => set({ resolved: resolvedOnly ? undefined : '1' })}>
          Resolved players only
        </button>
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
        <TileFrame title="Mentions" meta={`${rows.length} of ${data.rows.length}`} className="news-tile">
          {rows.length === 0 ? <p className="hint">No mentions match these filters.</p> : <Mentions rows={rows} sport={sport} />}
        </TileFrame>
      )}

      <TileFrame title="How this feed is built" className="note-tile" query={data?.query}>
        <p>
          One select on the news mentions mart for the window (and the team, when one is chosen). A row is one
          player mention in one article: the headline, the article's topic, the sentence about the player, how
          the name was resolved to a player, and the team's first scheduled game after the article with the
          opponent and the days until it. A name that resolved to no player keeps its row, marked unresolved, because it is still news about the
          team.
        </p>
      </TileFrame>
    </div>
  )
}

function groupOfPosition(m: MentionRow): string | null {
  return m.position_group ?? m.position ?? null
}

function Kpis({ data, shown }: { data: NewsPayload; shown: number }) {
  const players = new Set(data.rows.filter((m) => m.player_key).map((m) => m.player_key)).size
  const teams = data.teams.length
  const soon = data.rows.filter((m) => m.days_to_next_game !== null && m.days_to_next_game <= 3).length
  return (
    <div className="kpis four">
      <div className="kpi">
        <span className="l">Mentions</span>
        <span className="v">{data.rows.length}</span>
        <span className="s">{shown === data.rows.length ? `across ${data.feeds.length} feeds` : `${shown} shown after filters`}</span>
      </div>
      <div className="kpi">
        <span className="l">Players</span>
        <span className="v">{players}</span>
        <span className="s">{data.rows.length - data.rows.filter((m) => m.is_player_resolved).length} mentions did not resolve to a player</span>
      </div>
      <div className="kpi">
        <span className="l">Teams</span>
        <span className="v">{teams}</span>
        <span className="s">with at least one mention</span>
      </div>
      <div className="kpi">
        <span className="l">Playing within 3 days</span>
        <span className="v">{soon}</span>
        <span className="s">mentions whose team kicks off soon</span>
      </div>
    </div>
  )
}

function Mentions({ rows, sport }: { rows: MentionRow[]; sport: string }) {
  return (
    <ul className="mentions">
      {rows.map((m) => (
        <li key={m.mention_key} className={`mention ${m.is_player_resolved ? '' : 'unresolved'}`}>
          <div className="who">
            {m.player_key ? (
              <Link to={`/${sport}/players/${m.player_key}`}>
                <b>{m.player_name}</b>
              </Link>
            ) : (
              <b title="the name did not resolve to a player">{m.player_name ?? m.player_name_in_article}</b>
            )}
            <small>
              {[m.position, m.team_label ? <Link key="t" to={`/${sport}/teams/${m.team_label}`}>{m.team_label}</Link> : null]
                .filter(Boolean)
                .map((x, i) => (
                  <span key={i}>{i > 0 ? ' · ' : ''}{x}</span>
                ))}
              {!m.is_player_resolved && <span className="flag news"> unresolved</span>}
            </small>
          </div>
          <div className="what">
            {m.url ? (
              <a href={m.url} target="_blank" rel="noreferrer" className="headline">
                {m.headline ?? m.url}
              </a>
            ) : (
              <span className="headline">{m.headline}</span>
            )}
            {m.detail && <p className="ctx">{m.detail}</p>}
            <small>
              {m.context && <span className={`flag topic ${m.context}`}>{m.context}</span>}
              {m.feed} · {m.published_at.replace('T', ' ').slice(0, 16)}
            </small>
          </div>
          <div className="next">
            {m.next_game_key ? (
              <Link to={`/${sport}/games/${m.next_game_key}`}>
                <b>
                  {m.next_game_is_home ? 'vs' : 'at'} {m.next_opponent_label}
                </b>
                <small>
                  {m.next_game_season_type_name?.toLowerCase()} week {m.next_game_week}, in {m.days_to_next_game} day{m.days_to_next_game === 1 ? '' : 's'}
                </small>
              </Link>
            ) : (
              <small>no game scheduled</small>
            )}
          </div>
        </li>
      ))}
    </ul>
  )
}
