import type { ReactNode } from 'react'

interface Props {
  title: string
  count?: ReactNode
}

export function SectionHead({ title, count }: Props) {
  return (
    <div className="section-head">
      <h2>{title}</h2>
      {count == null ? null : <span className="count">{count}</span>}
    </div>
  )
}
