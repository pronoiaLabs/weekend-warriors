import { Link, useParams } from 'react-router-dom'
import { fetchGameSituations } from '../../../api/sports/client.ts'
import type { SituationRow } from '../../../api/sports/types.ts'
import CapabilityGate from '../../../components/sports/CapabilityGate.tsx'
import GameTabs from '../../../components/sports/GameTabs.tsx'
import TileFrame from '../../../components/sports/TileFrame.tsx'
import { useApi } from '../../../hooks/useApi.ts'
import { useBack } from '../../../hooks/useBack.ts'
import { useSportParam } from '../../../hooks/useSportParam.ts'
import { fmt, pct, signed } from '../../../lib/format.ts'
import { boardPath, useView } from '../../../state/view.tsx'

/** The situations room: each offense's splits beside what the OTHER side's
    defense allows in the same situation — the mart's side column carries both
    readings, so the pairing is a zip on situation_key, no math here. Season-
    level splits (a postseason game reads the regular season); thin cells gray
    by play count. */
export default function Situations() {
  return (
    <CapabilityGate cap="team_situation">
      <SituationsPage />
    </CapabilityGate>
  )
}

const GROUP_LABELS: Record<string, string> = {
  overall: 'All plays',
  down: 'By down',
  down_distance: 'By down & distance',
  field_zone: 'By field zone',
  script: 'By game script',
  play_family: 'By play family',
  two_minute: 'Two-minute',
}

const THIN_PLAYS = 20

function SituationsPage() {
  const sport = useSportParam()
  const { gameKey = '' } = useParams<{ gameKey: string }>()
  const { view } = useView()
  const res = useApi((signal) => fetchGameSituations(sport, gameKey, signal), [sport, gameKey])
  const boardHref = boardPath(sport, view)
  const back = useBack(boardHref)
  const data = res.data

  if (!data) {
    return (
      <div className="page page-game-situations">
        <GameTabs sport={sport} gameKey={gameKey} matchup={res.error ? 'No such game' : '...'} tab="Situations" boardHref={boardHref} back={back} />
        <div className="page-head">
          <h1>{res.error ? 'No such game' : 'Loading...'}</h1>
          {res.error && (
            <p className="lede">
              {res.error}. Pick a game from the <Link to={boardHref}>slate</Link>.
            </p>
          )}
        </div>
      </div>
    )
  }

  const matchup = `${data.away_team_label} @ ${data.home_team_label}`
  const empty = data.home_offense.length === 0 && data.away_offense.length === 0

  return (
    <div className="page page-game-situations">
      <GameTabs sport={sport} gameKey={gameKey} matchup={matchup} tab="Situations" boardHref={boardHref} back={back} />
      <div className="page-head">
        <h1>Situations</h1>
        <p className="lede">
          Each offense's {data.situation_season_type_name.toLowerCase()} splits, with what{' '}
          {data.season} opposing defenses allowed in the same situation beside them. Succ% is the
          share of plays with positive EPA; Expl% is a 20+ yard pass or 10+ yard rush.
        </p>
      </div>

      {empty ? (
        <section className="tile">
          <p className="hint">
            No situational play-by-play for this matchup yet
            {data.season_type_name === 'Preseason' ? ' — preseason has no play-by-play feed' : ''}. The{' '}
            <Link to={`/${sport}/plays`}>play log</Link> covers the regular season and playoffs.
          </p>
        </section>
      ) : (
        <div className="grid cols-game sit-grid">
          <SituationTile
            title={`${data.away_team_label} offense`}
            meta={`vs ${data.home_team_label} defense allowed · rows open the play log`}
            offense={data.away_offense}
            defense={data.home_defense}
            oppLabel={data.home_team_label}
            playsBase={`/${sport}/plays?game_key=${data.game_key}&team=${data.away_team_label}`}
          />
          <SituationTile
            title={`${data.home_team_label} offense`}
            meta={`vs ${data.away_team_label} defense allowed · rows open the play log`}
            offense={data.home_offense}
            defense={data.away_defense}
            oppLabel={data.away_team_label}
            playsBase={`/${sport}/plays?game_key=${data.game_key}&team=${data.home_team_label}`}
          />
        </div>
      )}

      <TileFrame title="How this screen is built" className="note-tile" query={data.query}>
        <p>
          One bound select on the team-situation mart for both teams; the mart's side column carries
          the offense and the defense-allowed readings of the same plays, so pairing a row with its
          opposite is a lookup, not a computation. Rates are season-level ratios of sums; cells
          under {THIN_PLAYS} plays render grayed.
        </p>
      </TileFrame>
    </div>
  )
}

/** The play-log params a situation row lands with. */
function situationSearch(group: string, key: string): string {
  if (group === 'down') return `&down_bucket=${key}`
  if (group === 'down_distance') {
    const m = key.match(/^(1st|2nd|3rd_4th)_(short|medium|long)$/)
    return m ? `&down_bucket=${m[1]}&distance_bucket=${m[2]}` : ''
  }
  if (group === 'field_zone') return `&field_zone=${key}`
  if (group === 'script') return `&script=${key}`
  if (group === 'play_family') return `&play_family=${key}`
  if (group === 'two_minute') return '&two_minute=true'
  return ''
}

function SituationTile({
  title,
  meta,
  offense,
  defense,
  oppLabel,
  playsBase,
}: {
  title: string
  meta: string
  offense: SituationRow[]
  defense: SituationRow[]
  oppLabel: string
  playsBase: string
}) {
  const allowedByKey = new Map(defense.map((r) => [r.situation_key, r]))
  const groups: { key: string; rows: SituationRow[] }[] = []
  for (const r of offense) {
    const last = groups[groups.length - 1]
    if (last && last.key === r.situation_group) last.rows.push(r)
    else groups.push({ key: r.situation_group, rows: [r] })
  }
  return (
    <TileFrame title={title} meta={meta} className="sit-tile">
      <div className="sit">
        <div className="sit-row head">
          <span>Situation</span>
          <span className="n">EPA</span>
          <span className="n">Succ%</span>
          <span className="n">Expl%</span>
          <span className="n opp">{oppLabel} EPA</span>
          <span className="n">Succ%</span>
          <span className="n">Expl%</span>
        </div>
        {groups.map((grp) => (
          <div key={grp.key} className="sit-group">
            {grp.key !== 'overall' && <div className="sit-sep">{GROUP_LABELS[grp.key] ?? grp.key}</div>}
            {grp.rows.map((r) => {
              const d = allowedByKey.get(r.situation_key)
              const thin = r.plays < THIN_PLAYS
              return (
                <Link
                  key={r.app_team_situation_key}
                  className={`sit-row${thin ? ' thin' : ''}`}
                  title={`${r.plays} plays · open in the play log`}
                  to={`${playsBase}${situationSearch(r.situation_group, r.situation_key)}`}
                >
                  <span className="what">
                    {r.situation_label}
                    <small>{fmt(r.plays)} plays</small>
                  </span>
                  <span className={`n ${lean(r.epa_vs_league)}`}>{signed(r.epa_per_play, 2)}</span>
                  <span className="n">{pct(r.success_rate)}</span>
                  <span className="n">{pct(r.explosive_rate)}</span>
                  <span className={`n opp ${d ? lean(d.epa_vs_league === null ? null : -d.epa_vs_league) : ''}`}>
                    {d ? signed(d.epa_per_play, 2) : '—'}
                  </span>
                  <span className="n">{d ? pct(d.success_rate) : '—'}</span>
                  <span className="n">{d ? pct(d.explosive_rate) : '—'}</span>
                </Link>
              )
            })}
          </div>
        ))}
      </div>
    </TileFrame>
  )
}

/** Color by distance from league average: a good offense number leans pos, a
    generous defense (for the offense reading it) leans pos too — the caller
    flips the sign for the allowed columns. */
function lean(vsLeague: number | null): string {
  if (vsLeague === null) return ''
  if (vsLeague > 0.03) return 'pos'
  if (vsLeague < -0.03) return 'neg'
  return ''
}
