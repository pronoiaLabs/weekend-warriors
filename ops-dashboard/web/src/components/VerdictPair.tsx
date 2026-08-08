/** TASK_STATE and DLT_STATUS side by side, never merged into one verdict: the
    whole point of a disagreement is that neither side has been ruled out, and
    the whole point of a missing record is that one side has nothing to say. */

type Variant = 'neutral' | 'alarmed' | 'missing'

interface Props {
  taskState: string | null
  dltStatus: string | null
  variant?: Variant
}

function valueClass(value: string | null): string {
  if (value == null) return 'val none'
  return value.toLowerCase() === 'failed' ? 'val bad' : 'val ok'
}

export function VerdictPair({ taskState, dltStatus, variant = 'neutral' }: Props) {
  // In the missing variant the right box is hatched and reads NULL whatever the
  // payload says: there is no _DLT_RUNS row to quote.
  const hatched = variant === 'missing'

  return (
    <div className={`vpair ${variant}`}>
      <div className="v">
        <div className="src">TASK_STATE</div>
        <div className={valueClass(taskState)}>{taskState ?? 'NULL'}</div>
        <div className="prov">what Snowflake saw · TASK_HISTORY</div>
      </div>
      <div className="vs">VS</div>
      <div className={hatched ? 'v hatch' : 'v'}>
        <div className="src">DLT_STATUS</div>
        <div className={hatched ? 'val none' : valueClass(dltStatus)}>
          {hatched ? 'NULL' : (dltStatus ?? 'NULL')}
        </div>
        <div className="prov">what the pipeline recorded · _DLT_RUNS</div>
      </div>
    </div>
  )
}
