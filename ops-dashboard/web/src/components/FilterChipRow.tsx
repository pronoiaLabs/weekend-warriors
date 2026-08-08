export interface FilterChip {
  value: string
  label: string
  count: number
  /** Pipelines needing a human, shown as a red suffix. Undefined when the
      current payload does not cover that sport, which is not the same as zero. */
  anomalies?: number
}

interface Props {
  caption?: string
  chips: FilterChip[]
  value: string
  onChange: (value: string) => void
}

export function FilterChipRow({ caption = 'Sport', chips, value, onChange }: Props) {
  return (
    <div className="chips" role="group" aria-label={`Filter by ${caption.toLowerCase()}`}>
      <span className="cap">{caption}</span>
      {chips.map((chip) => (
        <button
          key={chip.value}
          type="button"
          className={chip.value === value ? 'chip on' : 'chip'}
          aria-pressed={chip.value === value}
          onClick={() => onChange(chip.value)}
        >
          {chip.label}
          <span className="n">{chip.count}</span>
          {chip.anomalies ? <span className="warn">{'●'} {chip.anomalies}</span> : null}
        </button>
      ))}
    </div>
  )
}
