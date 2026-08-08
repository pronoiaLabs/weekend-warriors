import type { ReactNode } from 'react'

interface QuietNoteProps {
  children: ReactNode
}

export function QuietNote({ children }: QuietNoteProps) {
  return <p className="quiet-note">{children}</p>
}

interface EmptyStateProps {
  message: string
  detail?: string
  bad?: boolean
}

/** Loading and error states are one centered line: a dashboard that stalls
    should say so in words, not spin. */
export function EmptyState({ message, detail, bad }: EmptyStateProps) {
  return (
    <div className={bad ? 'page-state bad' : 'page-state'}>
      <div>{message}</div>
      {detail ? <div className="detail">{detail}</div> : null}
    </div>
  )
}
