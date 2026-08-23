export interface SelectItem {
  id: string
  label: string
}

/** A labelled native select drawn as a chip. The dashboard's Kind and Source
    filters use it so the filter row holds one line at any width; the active
    id is owned by the page (a URL param), same contract as Chips. A native
    control keeps keyboard and screen-reader behaviour for free. */
export default function Select({
  label,
  items,
  active,
  onPick,
}: {
  label: string
  items: SelectItem[]
  active: string
  onPick: (id: string) => void
}) {
  if (items.length === 0) return null
  const isDefault = items[0]?.id === active
  return (
    <label className="chip-group chip-select">
      <span className="chip-group-label">{label}</span>
      <span className={`chip select ${isDefault ? '' : 'on'}`}>
        <select value={active} onChange={(event) => onPick(event.target.value)} aria-label={label}>
          {items.map((it) => (
            <option key={it.id} value={it.id}>
              {it.label}
            </option>
          ))}
        </select>
        <span className="caret" aria-hidden="true">
          ▾
        </span>
      </span>
    </label>
  )
}
