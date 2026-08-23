import type { ReactNode } from 'react'

/** The glass tile every page composes: a title row, the body, an optional
    caption, and the "Show query" expander holding the SQL the API ran. Every
    tile that reads a mart passes its payload's query here, so the page never
    shows a number without the statement behind it. */
export default function TileFrame({
  title,
  meta,
  caption,
  query,
  className,
  tilt,
  children,
}: {
  title: ReactNode
  meta?: ReactNode
  caption?: ReactNode
  query?: string | null
  className?: string
  tilt?: boolean
  children: ReactNode
}) {
  return (
    <section className={`tile ${className ?? ''}`} data-tilt={tilt ? '' : undefined}>
      <header className="tile-head">
        <h2>{title}</h2>
        {meta !== undefined && meta !== null && <span className="meta">{meta}</span>}
      </header>
      <div className="tile-body">{children}</div>
      {caption && <p className="caption">{caption}</p>}
      {query && (
        <details className="q">
          <summary>Show query</summary>
          <pre>{query}</pre>
        </details>
      )}
    </section>
  )
}
