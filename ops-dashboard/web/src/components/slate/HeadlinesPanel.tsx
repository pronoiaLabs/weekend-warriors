import type { Headline, HeadlinesPayload } from '../../api/types.ts'
import { hhmm } from '../../utils/format.ts'
import TileFrame from '../TileFrame.tsx'

// Only these two earn the rose lead: ok and info are the wire noting things went
// to plan, and a plan going to plan is not an alarm.
const FLAGGED = new Set<string>(['fail', 'warn'])

/** The wire writes the entity into the headline itself, so the flag is a colour
    on the words already there rather than a second copy of the pipeline name. */
function HeadlineText({ item }: { item: Headline }) {
  if (!FLAGGED.has(item.severity) || !item.headline.startsWith(item.entity)) return <div className="h">{item.headline}</div>
  return (
    <div className="h">
      <span className="flag">{item.entity}</span>
      {item.headline.slice(item.entity.length)}
    </div>
  )
}

export function HeadlinesPanel({ wire }: { wire: HeadlinesPayload | null }) {
  return (
    <TileFrame
      title="Headlines"
      meta="the wire"
      caption={wire?.generated_at ? `compiled ${hhmm(wire.generated_at)} · AI_COMPLETE over the day's runs` : undefined}
    >
      {wire?.stale && wire.served_date && <div className="stale">wire from {wire.served_date}</div>}
      {wire && wire.headlines.length > 0 ? (
        <ul className="headlines">
          {wire.headlines.map((item) => (
            <li key={item.seq}>
              <HeadlineText item={item} />
              <div className="when">{item.detail}</div>
            </li>
          ))}
        </ul>
      ) : (
        <p className="hint">no wire yet</p>
      )}
    </TileFrame>
  )
}
