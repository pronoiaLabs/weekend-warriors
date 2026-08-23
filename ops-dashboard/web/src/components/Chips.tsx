export interface ChipItem {
  id: string
  label: string
  /** drawn rose when not active: a day with failures, a severity with lines */
  bad?: boolean
  /** amber: a no-show slot, not a run that broke */
  warn?: boolean
}

/** One row of toggle chips. The active id is owned by the page (usually a URL
    search param), so a choice survives reload and can be shared as a link. */
export default function Chips({
  items,
  active,
  onPick,
  label,
}: {
  items: ChipItem[]
  active: string | null
  onPick: (id: string) => void
  label: string
}) {
  if (items.length === 0) return null
  return (
    <div className="chip-group">
      <span className="chip-group-label">{label}</span>
      <div className="chips" role="group" aria-label={label}>
        {items.map((it) => (
          <button
            key={it.id}
            type="button"
            className={`chip ${it.id === active ? 'on' : ''} ${it.bad ? 'bad' : ''} ${it.warn ? 'warn' : ''}`}
            aria-pressed={it.id === active}
            onClick={() => onPick(it.id)}
          >
            {it.label}
          </button>
        ))}
      </div>
    </div>
  )
}
