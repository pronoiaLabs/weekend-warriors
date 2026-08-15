import type { Headline, HeadlinesPayload } from '../../api/types.ts'
import { hhmm } from '../../utils/format.ts'

// Only these two earn the red lead: ok and info are the wire noting things went
// to plan, and a plan going to plan is not an alarm.
const FLAGGED = new Set<string>(['fail', 'warn'])

interface HeadlinesPanelProps {
  wire: HeadlinesPayload | null
}

/** The wire writes the entity into the headline itself, so the flag is a colour
    on the words already there rather than a second copy of the pipeline name. */
function HeadlineText({ item }: { item: Headline }) {
  if (!FLAGGED.has(item.severity) || !item.headline.startsWith(item.entity)) {
    return <div className="h">{item.headline}</div>
  }
  return (
    <div className="h">
      <span className="flag">{item.entity}</span>
      {item.headline.slice(item.entity.length)}
    </div>
  )
}

export function HeadlinesPanel({ wire }: HeadlinesPanelProps) {
  return (
    <div className="sl-panel">
      <div className="sl-panel-head">
        <h3>Headlines</h3>
        <span className="sub">the wire</span>
      </div>

      {wire?.stale && wire.served_date ? (
        <div className="sl-stale">wire from {wire.served_date}</div>
      ) : null}

      {wire && wire.headlines.length > 0 ? (
        <ul className="sl-headlines">
          {wire.headlines.map((item) => (
            <li key={item.seq}>
              <HeadlineText item={item} />
              <div className="when">{item.detail}</div>
            </li>
          ))}
        </ul>
      ) : (
        <p className="sl-empty">no wire yet</p>
      )}

      {wire?.generated_at ? (
        <div className="sl-panel-foot">
          ✳ compiled {hhmm(wire.generated_at)} · AI_COMPLETE over the day's runs
        </div>
      ) : null}
    </div>
  )
}
