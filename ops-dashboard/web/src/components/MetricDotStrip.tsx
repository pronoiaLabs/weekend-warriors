import type { MetricPoint } from '../api/types.ts'
import { hhmmss, metricValue } from '../utils/format.ts'

interface Props {
  /** The metric's own name, e.g. container.cpu.usage. */
  name: string
  unit: string | null
  points: MetricPoint[]
  /** CPU_CORES_LIMIT or MEM_BYTES_REQUESTED, drawn as a dashed line. */
  limit: number | null
  limitLabel: string
  maxLabel: string
  max: number | null
  /** Scrapes, never METRIC_SAMPLES: a maximum is meaningless without the count
      of samples it was taken from, so the two always render together. */
  samplesLabel: string
  samples: number | null
  /** The run's own bounds, so a dot's x position is its real event time. */
  startAt: string
  endAt: string | null
}

/** Where the dashed limit line sits, as a share of the strip's height. Kept
    below the top edge so its label has somewhere to live. */
const LIMIT_TOP_PCT = 12

function xPct(at: string, startMs: number, spanMs: number): number {
  return Math.min(Math.max((Date.parse(at) - startMs) / spanMs, 0), 1) * 100
}

export function MetricDotStrip({
  name,
  unit,
  points,
  limit,
  limitLabel,
  maxLabel,
  max,
  samplesLabel,
  samples,
  startAt,
  endAt,
}: Props) {
  const startMs = Date.parse(startAt)
  const endMs = endAt ? Date.parse(endAt) : startMs + 1
  const spanMs = Math.max(endMs - startMs, 1)
  // The dashed line is the limit, so a dot's height is its share of the limit,
  // scaled into the band below that line. Without a limit the largest sample
  // anchors the band instead.
  const ceiling = limit ?? points.reduce((top, p) => Math.max(top, p.value ?? 0), 0) ?? 0

  return (
    <div className="mstrip">
      <div className="mhead">
        <span className="mname">
          {name}
          {unit ? ` (${unit})` : ''}
        </span>
        <span className="mmax">
          {maxLabel} <b>{metricValue(max, unit)}</b> of {limitLabel} {metricValue(limit, unit)} ·{' '}
          {samplesLabel} <b>{samples ?? 0}</b>
        </span>
      </div>

      <div className="strip">
        <div className="limit" style={{ top: `${LIMIT_TOP_PCT}%` }}>
          <small>
            {limitLabel} {metricValue(limit, unit)}
          </small>
        </div>
        {points.map((point) => (
          <span
            key={`${point.at}-${point.value}`}
            className="dot"
            style={{
              left: `${xPct(point.at, startMs, spanMs)}%`,
              bottom: `${
                ceiling > 0
                  ? Math.min(((point.value ?? 0) / ceiling) * (100 - LIMIT_TOP_PCT), 100)
                  : 50
              }%`,
            }}
            title={`${hhmmss(point.at)} · ${metricValue(point.value, unit)}`}
          />
        ))}
        {points.length === 0 ? (
          <span className="empty">no scrape landed inside this run</span>
        ) : null}
      </div>

      <div className="strip-scale">
        <span>{hhmmss(startAt)} run start</span>
        <span>{endAt ? `${hhmmss(endAt)} end` : 'no RUN_ENDED_AT'}</span>
      </div>
    </div>
  )
}
