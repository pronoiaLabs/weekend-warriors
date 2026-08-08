import type { AnomalyKind } from '../api/types.ts'

interface Verdict {
  label: string
  dot: string
  bad: boolean
}

// "disagree" is bad enough to earn a card but is never drawn red: the point of
// a disagreement is that neither verdict has been ruled out yet.
const VERDICTS: Record<AnomalyKind, Verdict> = {
  missing: { label: 'Record missing', dot: '▣', bad: true },
  missed: { label: 'Missed slot', dot: '!', bad: true },
  failure: { label: 'Failing', dot: '✕', bad: true },
  disagree: { label: 'Disagreement', dot: '≠', bad: false },
  ok: { label: 'Healthy', dot: '●', bad: false },
}

interface Props {
  state: AnomalyKind
}

export function StatusPill({ state }: Props) {
  const verdict = VERDICTS[state] ?? VERDICTS.ok
  return (
    <span className={verdict.bad ? 'pill bad' : 'pill'}>
      <span className="dot">{verdict.dot}</span> {verdict.label}
    </span>
  )
}
