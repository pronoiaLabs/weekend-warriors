import { num } from '../utils/format.ts'

interface Props {
  /** The Task's whole span, the number the bar is scaled against. */
  durationS: number | null
  /** Task dispatch plus SPCS scheduling and image pull, before the first log
      line. Rendered hatched. */
  startupOverheadS: number | null
  /** The container's own span, rendered solid. */
  containerSpanS: number | null
  failed?: boolean
  /** compact sits inside a run history row; labeled carries in-segment labels
      and a 0 to DURATION_S scale. */
  size?: 'compact' | 'labeled'
  /** The annotation only reads as a diagnosis on a run that died. */
  legend?: boolean
}

function pct(part: number, whole: number): number {
  return Math.min(Math.max((part / whole) * 100, 0), 100)
}

export function SegmentedDurationBar({
  durationS,
  startupOverheadS,
  containerSpanS,
  failed = false,
  size = 'compact',
  legend = true,
}: Props) {
  const labeled = size === 'labeled'

  if (durationS == null) {
    return (
      <div className={labeled ? 'durbar labeled' : 'durbar'}>
        <div className="dur-legend">
          DURATION_S is NULL on this row, so there is no span to split.
        </div>
      </div>
    )
  }

  // Either half can be NULL: only the runs the telemetry join reached carry
  // CONTAINER_SPAN_S, and STARTUP_OVERHEAD_S is derived from it. The bar then
  // degenerates to one unsplit segment rather than inventing a seam.
  const split = startupOverheadS != null && containerSpanS != null
  const startupPct = split ? pct(startupOverheadS, durationS) : 0
  const workPct = split ? pct(containerSpanS, durationS) : 100

  return (
    <div className={labeled ? 'durbar labeled' : 'durbar'}>
      <div className="bar">
        {split ? (
          <div className="seg startup" style={{ width: `${startupPct}%` }}>
            {labeled ? <span>STARTUP_OVERHEAD_S {startupOverheadS}</span> : null}
          </div>
        ) : null}
        <div className={failed ? 'seg work fail' : 'seg work'} style={{ width: `${workPct}%` }}>
          {labeled ? (
            <span>
              {split ? `CONTAINER_SPAN_S ${containerSpanS}` : `DURATION_S ${durationS}`}
              {failed ? ' · ended in failure' : ''}
            </span>
          ) : null}
        </div>
      </div>

      {labeled ? (
        <div className="dur-scale">
          <span>0s</span>
          <span>DURATION_S {num(durationS)}</span>
        </div>
      ) : null}

      {legend ? (
        <div className="dur-legend">
          {split ? (
            <>
              DURATION_S <b>{durationS} s</b> splits into STARTUP_OVERHEAD_S{' '}
              <b>{startupOverheadS} s</b> (hatched) and CONTAINER_SPAN_S <b>{containerSpanS} s</b>{' '}
              (solid).{' '}
              {failed
                ? 'A run that dies in the hatched zone is an infrastructure or spec problem; this one died in the solid zone, so the problem is data or API.'
                : 'Startup is a fixed cost per run, which is why a short pipeline never finishes much faster.'}
            </>
          ) : (
            <>
              DURATION_S <b>{durationS} s</b> · CONTAINER_SPAN_S and STARTUP_OVERHEAD_S are NULL on
              this row, so the hatched startup zone cannot be separated from the work zone and the
              whole span renders as one segment.
            </>
          )}
        </div>
      ) : null}
    </div>
  )
}
