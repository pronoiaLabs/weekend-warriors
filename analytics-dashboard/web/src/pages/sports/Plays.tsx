import { Link, useSearchParams } from 'react-router-dom'
import { fetchPlays } from '../../api/sports/client.ts'
import type { PlayRow, PlaysPayload } from '../../api/sports/types.ts'
import Avatar from '../../components/sports/Avatar.tsx'
import CapabilityGate from '../../components/sports/CapabilityGate.tsx'
import Crumbs from '../../components/sports/Crumbs.tsx'
import TeamLogo from '../../components/sports/TeamLogo.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useBack } from '../../hooks/useBack.ts'
import { teamAccent, useBranding } from '../../hooks/useBranding.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { pct, signed } from '../../lib/format.ts'

export default function Plays() {
  return (
    <CapabilityGate cap="play_log">
      <PlayLog />
    </CapabilityGate>
  )
}

/** The pattern room: every play, drive by drive, at the grain where patterns
    live. Arrivals come pre-filtered (a situation cell lands with its filters
    already set); the filter rail is plain query params — the session agent
    that will drive this screen is a later arc. */

const SEASONS = [2026, 2025, 2024, 2023]
const SELECTS: { key: string; label: string; options: [string, string][] }[] = [
  {
    key: 'down_bucket',
    label: 'Down',
    options: [
      ['1st', '1st'],
      ['2nd', '2nd'],
      ['3rd_4th', '3rd/4th'],
    ],
  },
  {
    key: 'distance_bucket',
    label: 'Dist',
    options: [
      ['short', 'short 1-3'],
      ['medium', 'med 4-7'],
      ['long', 'long 8+'],
    ],
  },
  {
    key: 'field_zone',
    label: 'Zone',
    options: [
      ['own', 'own'],
      ['mid', 'midfield'],
      ['red_zone', 'red zone'],
    ],
  },
  {
    key: 'script',
    label: 'Script',
    options: [
      ['leading', 'leading'],
      ['neutral', 'tied'],
      ['trailing', 'trailing'],
    ],
  },
  {
    key: 'play_family',
    label: 'Play',
    options: [
      ['dropback', 'pass'],
      ['designed_run', 'run'],
      ['special', 'special'],
    ],
  },
]
const TOGGLES: { key: string; label: string }[] = [
  { key: 'shotgun', label: 'shotgun' },
  { key: 'no_huddle', label: 'no-huddle' },
  { key: 'two_minute', label: 'two-minute' },
]
const SITUATION_KEYS = ['down_bucket', 'distance_bucket', 'field_zone', 'script', 'play_family', 'shotgun', 'no_huddle', 'two_minute']

function PlayLog() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const branding = useBranding(sport)
  const [search, setSearch] = useSearchParams()
  const back = useBack(`/${sport}/slate`)

  const p = (k: string) => search.get(k) ?? undefined
  const gameKey = p('game_key')
  const playerKey = p('player_key')
  const team = p('team')
  const anchored = Boolean(gameKey || playerKey || team)
  const params = {
    season: p('season') ? Number(p('season')) : undefined,
    week: p('week') ? Number(p('week')) : undefined,
    game_key: gameKey,
    player_key: playerKey,
    team,
    down_bucket: p('down_bucket'),
    distance_bucket: p('distance_bucket'),
    field_zone: p('field_zone'),
    script: p('script'),
    play_family: p('play_family'),
    shotgun: search.get('shotgun') === 'true' ? true : undefined,
    no_huddle: search.get('no_huddle') === 'true' ? true : undefined,
    two_minute: search.get('two_minute') === 'true' ? true : undefined,
  }

  const res = useApi(
    (signal) => (anchored ? fetchPlays(sport, params, signal) : Promise.resolve(null)),
    [sport, search.toString(), anchored],
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
  const teamOptions = [...branding.values()].sort((a, b) => a.team_label.localeCompare(b.team_label))
  // game-mode arrivals return the whole game so context stays visible: rows
  // matching the situational filters highlight, the rest dim. Player/team
  // arrivals were filtered in SQL, so everything shown is a hit.
  const situationalActive = SITUATION_KEYS.some((k) => search.get(k))
  const gameMode = Boolean(gameKey)
  const hits = data ? data.rows.filter((r) => matchesSituation(r, search)).length : 0

  return (
    <div className="page page-plays">
      <div className="crumb-row">
        <Crumbs
          items={[
            ...(data?.player_name ? [{ label: 'Players', to: `/${sport}/players` }] : []),
            { label: data?.player_name ?? team ?? 'League' },
            { label: 'Play log' },
          ]}
        />
        <button type="button" className="back" onClick={back}>
          <span aria-hidden="true">←</span> Back
        </button>
      </div>

      <div className="page-head">
        <h1>
          Play Log <span className="hint">· the pattern room</span>
        </h1>
        <p className="lede">
          Every play, drive by drive, at the grain where patterns live. Anchor the feed with a game, a
          team or a player; the situation filters cut it to the pattern that raised the question.
        </p>
      </div>

      <div className="filters frail">
        <label className="psel-wrap">
          Season
          <select className="psel" value={params.season ?? ''} onChange={(e) => set({ season: e.target.value || undefined })}>
            <option value="">current</option>
            {SEASONS.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </label>
        <label className="psel-wrap">
          Week
          <select className="psel" value={params.week ?? ''} onChange={(e) => set({ week: e.target.value || undefined })}>
            <option value="">all</option>
            {Array.from({ length: 22 }, (_, i) => i + 1).map((w) => (
              <option key={w} value={w}>
                {w}
              </option>
            ))}
          </select>
        </label>
        <label className="psel-wrap">
          Team
          <select className="psel" value={team ?? ''} onChange={(e) => set({ team: e.target.value || undefined })}>
            <option value="">{gameKey || playerKey ? 'any' : 'pick a team'}</option>
            {teamOptions.map((t) => (
              <option key={t.team_key} value={t.team_label}>
                {t.team_label}
              </option>
            ))}
          </select>
        </label>
        {data?.player_name && playerKey && (
          <button type="button" className="chip on" onClick={() => set({ player_key: undefined })} title="Clear the player">
            <Avatar name={data.player_name} size="sm" /> {data.player_name} ✕
          </button>
        )}
        <span className="sep" aria-hidden="true" />
        {SELECTS.map((sel) => (
          <label key={sel.key} className="psel-wrap">
            {sel.label}
            <select className="psel" value={p(sel.key) ?? ''} onChange={(e) => set({ [sel.key]: e.target.value || undefined })}>
              <option value="">any</option>
              {sel.options.map(([v, l]) => (
                <option key={v} value={v}>
                  {l}
                </option>
              ))}
            </select>
          </label>
        ))}
        {TOGGLES.map((t) => (
          <button
            key={t.key}
            type="button"
            className={`chip ${search.get(t.key) === 'true' ? 'on' : ''}`}
            onClick={() => set({ [t.key]: search.get(t.key) === 'true' ? undefined : 'true' })}
          >
            {t.label}
          </button>
        ))}
      </div>

      {data && data.usage.length > 0 && (
        <TileFrame title="Situational usage — pinned" meta={`target share by bucket · ${data.season}`} className="usage-strip-tile">
          <div className="ustrip">
            <span className="whois">
              <Avatar name={data.player_name ?? ''} size="lg" />
              <span className="id">
                <b>{data.player_name}</b>
                <small>{data.usage[0]?.position ?? ''} · lit cells match the active filters</small>
              </span>
            </span>
            {data.usage.map((u) => {
              const hot =
                (u.bucket_type === 'down' && p('down_bucket') === u.bucket) ||
                (u.bucket_type === 'field_zone' && p('field_zone') === u.bucket) ||
                (u.bucket_type === 'script' && p('script') === u.bucket)
              return (
                <span key={u.app_player_situation_usage_key} className={`u ${hot ? 'hot' : ''}`}>
                  <label>{u.bucket_label}</label>
                  <b>{pct(u.target_share, 0)}</b>
                  <small className={u.share_vs_league === null ? '' : u.share_vs_league >= 0 ? 'pos' : 'neg'}>
                    {u.share_vs_league === null ? '—' : `${signed((u.share_vs_league ?? 0) * 100, 0)} vs league`}
                  </small>
                </span>
              )
            })}
          </div>
        </TileFrame>
      )}

      {!anchored && (
        <section className="tile">
          <header className="tile-head">
            <h2>Anchor the feed</h2>
          </header>
          <p className="hint">
            The play feed is one shot, never paged, so it needs an anchor: pick a team above, open a game's
            Situations tab, or arrive from a player's game log. {label} play-by-play covers the regular
            season and playoffs.
          </p>
        </section>
      )}

      {anchored && res.error && !data && (
        <section className="tile">
          <header className="tile-head">
            <h2>Nothing to show</h2>
          </header>
          <p className="hint">{res.error}</p>
        </section>
      )}

      {data && (
        <TileFrame
          title="Play feed"
          meta={`${data.rows.length}${data.has_more ? '+' : ''} plays · ${countDrives(data.rows)} drives${
            gameMode && situationalActive ? ` · ${hits} match the pattern` : ''
          }${data.has_more ? ' · capped, narrow with week' : ''}`}
          className="feed-tile"
          query={data.query}
        >
          {data.rows.length === 0 ? (
            <p className="hint">
              No plays for this slice. Play-by-play covers the regular season and playoffs — the preseason
              has none, honestly.
            </p>
          ) : (
            <Feed data={data} branding={branding} sport={sport} search={search} gameMode={gameMode} situationalActive={situationalActive} />
          )}
        </TileFrame>
      )}
    </div>
  )
}

function matchesSituation(r: PlayRow, search: URLSearchParams): boolean {
  const eq = (k: string, v: string | boolean | null) => {
    const want = search.get(k)
    if (want === null) return true
    if (typeof v === 'boolean') return want === 'true' ? v : true
    return v === want
  }
  return (
    eq('down_bucket', r.down_bucket) &&
    eq('distance_bucket', r.distance_bucket) &&
    eq('field_zone', r.field_zone) &&
    eq('script', r.game_script) &&
    eq('play_family', r.play_family) &&
    eq('shotgun', r.shotgun ?? false) &&
    eq('no_huddle', r.no_huddle ?? false) &&
    eq('two_minute', r.is_two_minute ?? false)
  )
}

function countDrives(rows: PlayRow[]): number {
  const keys = new Set<string>()
  for (const r of rows) keys.add(`${r.game_key}:${r.drive_number ?? `q${r.quarter}`}`)
  return keys.size
}

interface Drive {
  key: string
  game_key: string
  rows: PlayRow[]
  first: PlayRow
}

function groupDrives(rows: PlayRow[]): Drive[] {
  const drives: Drive[] = []
  let current: Drive | null = null
  for (const r of rows) {
    const key = `${r.game_key}:${r.drive_number ?? `q${r.quarter}`}`
    if (!current || current.key !== key) {
      current = { key, game_key: r.game_key, rows: [], first: r }
      drives.push(current)
    }
    current.rows.push(r)
  }
  return drives
}

function Feed({
  data,
  branding,
  sport,
  search,
  gameMode,
  situationalActive,
}: {
  data: PlaysPayload
  branding: ReturnType<typeof useBranding>
  sport: string
  search: URLSearchParams
  gameMode: boolean
  situationalActive: boolean
}) {
  const drives = groupDrives(data.rows)
  return (
    <div className="feed-scroll">
      {drives.map((d) => {
        const f = d.first
        const accent = teamAccent(branding.get(f.team_key ?? ''))
        return (
          <div key={d.key} className="drive">
            <div className="drive-head" style={accent ? ({ '--team': accent } as React.CSSProperties) : undefined}>
              <span className="team-bar" aria-hidden="true" />
              <TeamLogo teamKey={f.team_key} label={f.team_label} branding={branding} size="sm" />
              <Link className="dh" to={`/${sport}/games/${d.game_key}`} title="Open the game">
                <b>{f.team_label ?? '—'} drive</b>
                <span className="dsum">
                  {f.drive_number === null
                    ? `Q${f.quarter ?? '?'} · ${d.rows.length} plays`
                    : [
                        `${f.drive_play_count ?? d.rows.length} plays`,
                        f.drive_yards !== null ? `${f.drive_yards} yds` : null,
                        f.drive_time_of_possession,
                        f.drive_result,
                      ]
                        .filter(Boolean)
                        .join(' · ')}
                </span>
              </Link>
              <span className="score">
                Wk {f.week} {f.is_home_possession === null ? '' : f.is_home_possession ? 'vs' : '@'} {f.opponent_label ?? ''}
                {f.game_script ? ` · ${f.game_script}` : ''}
              </span>
            </div>
            <div className="plays">
              {d.rows.map((r) => {
                const hit = matchesSituation(r, search)
                const dim = gameMode && situationalActive && !hit
                const lit = gameMode && situationalActive && hit
                return (
                  <div key={r.play_key} className={`play ${lit ? 'hit' : ''} ${dim ? 'dim' : ''}`}>
                    <span className="sit">
                      <b>{r.down ? `${ordinalDown(r.down)} & ${r.distance ?? '—'}` : (r.play_category ?? '')}</b>
                      <small>
                        Q{r.quarter ?? '?'} · {r.yards_to_endzone !== null ? `${r.yards_to_endzone} to go` : ''} ·{' '}
                        {r.clock_display ?? ''}
                      </small>
                    </span>
                    <span className="ptext">{r.play_description ?? '—'}</span>
                    <span className="mx-row">
                      {r.epa !== null && (
                        <span className={`mx ${r.epa >= 0 ? 'pos' : 'neg'}`}>{signed(r.epa, 2)} epa</span>
                      )}
                      {r.wpa !== null && (
                        <span className={`mx ${r.wpa >= 0 ? 'pos' : 'neg'}`}>{signed(r.wpa * 100, 1)} wp</span>
                      )}
                      {r.success !== null && <span className={`mx ${r.success ? 'pos' : 'neg'}`}>{r.success ? '✓' : '✗'}</span>}
                    </span>
                    <span className="pwho">
                      {(
                        [
                          [r.passer_player_key, r.passer_name],
                          [r.rusher_player_key, r.rusher_name],
                          [r.receiver_player_key, r.receiver_name],
                        ] as [string | null, string | null][]
                      )
                        .filter(([k]) => k !== null)
                        .map(([k, n]) => (
                          <Link key={k} to={`/${sport}/players/${k}?season=${r.season}`} title={n ?? ''}>
                            <Avatar name={n ?? '?'} size="sm" />
                          </Link>
                        ))}
                    </span>
                  </div>
                )
              })}
            </div>
          </div>
        )
      })}
    </div>
  )
}

function ordinalDown(down: number): string {
  return ['', '1st', '2nd', '3rd', '4th'][down] ?? String(down)
}
