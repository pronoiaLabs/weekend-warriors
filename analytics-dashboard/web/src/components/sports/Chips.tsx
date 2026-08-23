export interface ChipItem {
  id: string
  label: string
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
    <div className="chips" role="group" aria-label={label}>
      {items.map((it) => (
        <button
          key={it.id}
          type="button"
          className={`chip ${it.id === active ? 'on' : ''}`}
          aria-pressed={it.id === active}
          onClick={() => onPick(it.id)}
        >
          {it.label}
        </button>
      ))}
    </div>
  )
}
