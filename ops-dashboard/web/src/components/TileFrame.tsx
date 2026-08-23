import type { ReactNode } from 'react'

/** The glass tile every page composes: a title row, the body, an optional
    caption, and the "Show query" expander holding the SQL the API ran. The
    ops API does not ship its SQL yet; the expander appears as soon as a
    payload carries `query`, so the tiles need no change when it does. */
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
