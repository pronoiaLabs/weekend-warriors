import type { CSSProperties, ReactNode } from 'react'

interface Props {
  label: string
  children: ReactNode
  style?: CSSProperties
}

export function AnnotationNote({ label, children, style }: Props) {
  return (
    <div className="note" style={style}>
      <strong>{label}</strong> {children}
    </div>
  )
}
