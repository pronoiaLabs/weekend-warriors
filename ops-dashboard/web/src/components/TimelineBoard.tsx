import type { CSSProperties, ReactNode } from 'react'
import { Link } from 'react-router-dom'
import type { Block, BoardSport, BoardWindow, Sublane } from '../api/types.ts'
import { useSportFilter } from '../hooks/useSportFilter.ts'
import { dayHhmm, hhmm, num } from '../utils/format.ts'
import type { Scale } from '../utils/timeline.ts'
import {
  axisTicks,
  blockWidthPx,
  makeScale,
  positionPct,
  sortByTime,
  staggerRows,
  withinWindow,
} from '../utils/timeline.ts'
import { Expander } from './Expander.tsx'

const KNOWN_STATES = new Set(['succeeded', 'failure', 'missing', 'missed', 'upcoming'])

const STATE_WORDS: Record<string, string> = {
  succeeded: 'SUCCEEDED',
  failure: 'FAILED',
  missing: 'FAILED, DLT_RECORD_MISSING',
  missed: 'cron slot passed, no run row',
  upcoming: 'scheduled, not yet fired',
}

function stateClass(state: string): string {
  return KNOWN_STATES.has(state) ? state : 'unknown'
}

function glyph(state: string, at: string): ReactNode {
  switch (stateClass(state)) {
    case 'succeeded':
      return '✓'
    case 'failure':
      return '✗'
    case 'missing':
      return <em>▣</em>
    case 'missed':
      return '!'
    case 'upcoming':
      return hhmm(at)
    default:
      return '·'
  }
}

function blockTitle(block: Block): string {
  const parts = [
    `${block.pipeline} ${hhmm(block.at)}`,
    STATE_WORDS[stateClass(block.state)] ?? block.state.toUpperCase(),
  ]
  if (block.duration_s != null) parts.push(`DURATION_S ${block.duration_s}`)
  if (block.rows_loaded != null) parts.push(`ROWS_LOADED ${num(block.rows_loaded)}`)
  if (block.error_excerpt) parts.push(block.error_excerpt)
  return parts.join(', ')
}

interface BlockProps {
  block: Block
  scale: Scale
  compact?: boolean
  row?: number
  incidentsSearch: string
}

function TimelineBlock({ block, scale, compact, row, incidentsSearch }: BlockProps) {
  const classes = ['run', 'st', `st-${stateClass(block.state)}`]
  if (compact) classes.push('sm', row === 1 ? 'r2' : 'r1')

  const style: CSSProperties = {
    left: `${positionPct(scale, block.at)}%`,
    width: `${blockWidthPx(block, compact)}px`,
  }
  const body = glyph(block.state, block.at)
  const title = blockTitle(block)

  // Absence has no run row to open, so it routes to the incident feed instead.
  if (block.kind === 'missed') {
    return (
      <Link
        className={classes.join(' ')}
        style={style}
        title={title}
        to={{ pathname: '/incidents', search: incidentsSearch }}
      >
        {body}
      </Link>
    )
  }
  if (block.kind === 'run' && block.query_id) {
    return (
      <Link
        className={classes.join(' ')}
        style={style}
        title={title}
        to={`/runs/${block.query_id}`}
      >
        {body}
      </Link>
    )
  }
  return (
    <span className={classes.join(' ')} style={style} title={title}>
      {body}
    </span>
  )
}

function NowLine({ scale, now, flag }: { scale: Scale; now: string; flag?: boolean }) {
  if (!withinWindow(scale, now)) return null
  return (
    <div className="now-line" style={{ left: `${positionPct(scale, now)}%` }}>
      {flag ? <span className="flag">NOW {hhmm(now)}</span> : null}
    </div>
  )
}

function laneSummary(sublanes: Sublane[], blocks: Block[]): ReactNode {
  const counted = (state: string) => blocks.filter((block) => block.state === state).length
  const problems: string[] = []
  const failed = counted('failure')
  const missing = counted('missing')
  const missed = counted('missed')
  if (failed) problems.push(`${failed} failed`)
  if (missing) problems.push(`${missing} record missing`)
  if (missed) problems.push(`${missed} missed slot${missed > 1 ? 's' : ''}`)

  return (
    <>
      {sublanes.length} pipelines ·{' '}
      {problems.length ? <b className="bad">{problems.join(' · ')}</b> : 'all quiet'}
    </>
  )
}

function sublaneSub(lane: Sublane): string {
  const parts = [lane.schedule]
  if (lane.last_duration_s != null) parts.push(`last ${lane.last_duration_s}s`)
  if (lane.last_rows_loaded != null) parts.push(`${num(lane.last_rows_loaded)} rows`)
  return parts.join(' · ')
}

interface Props {
  window: BoardWindow
  now: string
  sports: BoardSport[]
  isExpanded: (sport: string) => boolean
  onToggle: (sport: string) => void
}

export function TimelineBoard({ window: boardWindow, now, sports, isExpanded, onToggle }: Props) {
  const { search } = useSportFilter()
  const scale = makeScale(boardWindow)
  const ticks = axisTicks(scale)
  const trackStyle = { '--grid-step': `${100 / Math.max(ticks.length, 1)}%` } as CSSProperties

  return (
    <div className="board">
      <div className="board-head">
        <div className="lane-label">Sport · expand for pipelines</div>
        <div className="axis">
          {ticks.map((at) => (
            <span key={at} style={{ left: `${positionPct(scale, new Date(at).toISOString())}%` }}>
              {hhmm(new Date(at).toISOString())}
            </span>
          ))}
        </div>
      </div>

      {sports.map((sport) => {
        const open = isExpanded(sport.sport)
        const blocks = sortByTime(sport.blocks)
        const rows = staggerRows(blocks, scale)

        return (
          <div className="sport-block" key={sport.sport}>
            <div className="lane sport-lane">
              <div className="lane-label">
                <Expander
                  open={open}
                  onToggle={() => onToggle(sport.sport)}
                  label={`${open ? 'Collapse' : 'Expand'} ${sport.sport} pipeline lanes`}
                />
                <div>
                  <div className="sportname">{sport.sport}</div>
                  <div className="sub">{laneSummary(sport.sublanes, sport.blocks)}</div>
                </div>
              </div>
              <div className="track tall" style={trackStyle}>
                <NowLine scale={scale} now={now} flag />
                {blocks.map((block, index) => (
                  <TimelineBlock
                    key={`${block.pipeline}-${block.at}-${block.state}`}
                    block={block}
                    scale={scale}
                    compact
                    row={rows[index]}
                    incidentsSearch={search}
                  />
                ))}
              </div>
            </div>

            {open ? (
              <div className="sublanes">
                {sport.sublanes.map((lane) => (
                  <div className="lane" key={lane.pipeline}>
                    <div className="lane-label">
                      <div className="name">
                        <Link to={`/ingestion/${sport.sport}/${lane.pipeline}`}>
                          {lane.pipeline}
                        </Link>
                      </div>
                      <div className="sub">{sublaneSub(lane)}</div>
                    </div>
                    {/* A lane with no slots today stays on screen: a pipeline that
                        quietly stopped being scheduled is itself worth seeing. */}
                    {lane.not_scheduled_today ? (
                      <div className="track notsched" style={trackStyle}>
                        <span className="ns-note">
                          not scheduled today · next: {dayHhmm(lane.next_fire)}
                        </span>
                      </div>
                    ) : (
                      <div className="track" style={trackStyle}>
                        <NowLine scale={scale} now={now} />
                        {sortByTime(lane.blocks).map((block) => (
                          <TimelineBlock
                            key={`${block.at}-${block.state}`}
                            block={block}
                            scale={scale}
                            incidentsSearch={search}
                          />
                        ))}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            ) : null}
          </div>
        )
      })}
    </div>
  )
}
