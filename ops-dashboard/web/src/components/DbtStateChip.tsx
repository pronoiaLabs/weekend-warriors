/** A dbt build state is not one of the pipeline states, so it does not go
    through StatusPill: SUCCESS is not "healthy" and a build that is still
    RUNNING has no pipeline equivalent at all. The chip borrows the shared
    `.st-*` status vocabulary for colour and nothing else, and any state the
    backend does not classify renders neutrally rather than being guessed at. */

const STATE_CLASS: Record<string, string> = {
  succeeded: 'st-succeeded',
  success: 'st-succeeded',
  failed: 'st-failure',
  failure: 'st-failure',
  failed_and_auto_suspended: 'st-failure',
  running: 'st-upcoming',
  executing: 'st-upcoming',
  scheduled: 'st-upcoming',
  cancelled: 'st-notsched',
  skipped: 'st-notsched',
}

interface Props {
  state: string
}

export function DbtStateChip({ state }: Props) {
  const key = state.toLowerCase()
  return (
    <span className={`dbt-state ${STATE_CLASS[key] ?? 'st-unknown'}`} title={state}>
      {key}
    </span>
  )
}
