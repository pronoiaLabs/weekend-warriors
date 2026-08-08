import type { IncidentKind } from '../api/types.ts'

// Severity is a class, not a score. RECORD MISSING is the solid red because it
// destroys the evidence a failure would leave, MISSED SLOT is dashed to match
// the dashed slot on the schedule board, and DISAGREEMENT is neutral gray: the
// run may be fine, and painting it red trains people to ignore red. The kind is
// also the CSS class, so the enclosing article's left strip is `sev-<kind>`
// without a second vocabulary to keep in step.
const SEVERITIES: Record<IncidentKind, { glyph: string; label: string }> = {
  missing: { glyph: '▣', label: 'RECORD MISSING' },
  missed: { glyph: '!', label: 'MISSED SLOT' },
  failure: { glyph: '✕', label: 'FAILURE' },
  disagree: { glyph: '◔', label: 'DISAGREEMENT' },
}

interface Props {
  kind: IncidentKind
}

export function SeverityBadge({ kind }: Props) {
  const severity = SEVERITIES[kind]
  return (
    <span className={`sev ${kind}`}>
      {severity.glyph} {severity.label}
    </span>
  )
}
