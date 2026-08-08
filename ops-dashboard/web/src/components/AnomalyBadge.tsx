import type { AnomalyKind } from '../api/types.ts'
import { shortDate } from '../utils/format.ts'

interface Props {
  kind: AnomalyKind
  count?: number
  windowDays?: number
  lastAt?: string
}

export function AnomalyBadge({ kind, count = 1, windowDays, lastAt }: Props) {
  const times = count > 1 ? `${count}x ` : ''
  const window = windowDays ? ` · ${windowDays} D` : ''

  if (kind === 'missing') {
    return <span className="anom hard">{`${times}RECORD MISSING${window}`}</span>
  }
  if (kind === 'missed') {
    return <span className="anom missed">{`${times}MISSED SLOT`}</span>
  }
  if (kind === 'disagree') {
    // Neutral by design: a disagreement is a finding, not a red state.
    return (
      <span className="anom neutral">
        {`${times}DISAGREES${lastAt ? ` · ${shortDate(lastAt)}` : window}`}
      </span>
    )
  }
  if (kind === 'failure') {
    return <span className="anom">{`${times}FAILING${window}`}</span>
  }
  return null
}
