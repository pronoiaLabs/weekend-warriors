const KEYS: { state: string; text: string }[] = [
  { state: 'succeeded', text: 'succeeded (✓)' },
  { state: 'failure', text: 'failed (✗)' },
  { state: 'missing', text: 'failed, DLT_RECORD_MISSING (▣)' },
  { state: 'missed', text: 'expected but no run row (!)' },
  { state: 'upcoming', text: 'upcoming cron slot' },
  { state: 'notsched', text: 'not scheduled today' },
]

export function Legend() {
  return (
    <div className="legend">
      {KEYS.map((key) => (
        <span className="key" key={key.state}>
          <span className={`swatch st st-${key.state}`} /> {key.text}
        </span>
      ))}
    </div>
  )
}
