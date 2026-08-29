import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { fetchCatalog, fetchSheet } from '../../api/sports/client.ts'
import type { SheetPayload, SheetRef } from '../../api/sports/types.ts'
import Chips from '../../components/sports/Chips.tsx'
import TileFrame from '../../components/sports/TileFrame.tsx'
import { useApi } from '../../hooks/useApi.ts'
import { useSportParam } from '../../hooks/useSportParam.ts'
import { useCapabilities } from '../../layouts/SportLayout.tsx'
import { fmt } from '../../lib/format.ts'
import { AGGS, FILTERABLE, defaultMeasure, distinct, formatCell, isNumeric, pivot, stats, tsv, type Agg, type Row } from '../../lib/sheet.ts'

const MAX_CHIPS = 20

const LIMITS = [100, 500, 2000]

export default function Explore() {
  const sport = useSportParam()
  const caps = useCapabilities()
  const catalog = useApi((signal) => fetchCatalog(sport, signal), [sport])
  const label = caps?.label ?? sport.toUpperCase()

  if (!catalog.data) {
    return (
      <div className="page page-explore">
        <div className="page-head">
          <h1>Explorer</h1>
          <p className="lede">{catalog.error ?? 'Loading the sheets...'}</p>
        </div>
      </div>
    )
  }
  if (catalog.data.sheets.length === 0) {
    return (
      <div className="page page-explore">
        <div className="page-head">
          <h1>Explorer</h1>
          <p className="lede">No sheets yet for {label}: the explore tables arrive with that sport's APP layer.</p>
        </div>
      </div>
    )
  }
  return <Sheets sheets={catalog.data.sheets} catalogQuery={catalog.data.query} sport={sport} label={label} />
}

function Sheets({ sheets, catalogQuery, sport, label }: { sheets: SheetRef[]; catalogQuery: string | null; sport: string; label: string }) {
  const [search, setSearch] = useSearchParams()
  // every choice is in the URL: the sheet, the where pairs, the free-text
  // where bar, the sort, the page size
  const sheetId = sheets.some((s) => s.id === search.get('sheet')) ? search.get('sheet')! : sheets[0]!.id
  const sheet = sheets.find((s) => s.id === sheetId)!
  const where = search.getAll('where')
  const q = search.get('q') ?? undefined
  const order = search.get('order') ?? undefined
  const desc = search.get('desc') === '1'
  const limitParam = Number(search.get('limit'))
  const limit = LIMITS.includes(limitParam) ? limitParam : 500
  const offset = Number(search.get('offset')) || 0
  // the input is free-typed and committed on Enter or blur, so a half-written
  // clause never fires a 400 mid-keystroke
  const [draft, setDraft] = useState(q ?? '')
  useEffect(() => setDraft(q ?? ''), [q, sheetId])

  const res = useApi((signal) => fetchSheet(sport, sheetId, { where, q, order, desc, limit, offset }, signal), [sport, sheetId, where.join('|'), q ?? '', order, desc, limit, offset])

  const set = (patch: Record<string, string | string[] | undefined>) => {
    const next = new URLSearchParams(search)
    for (const [k, v] of Object.entries(patch)) {
      next.delete(k)
      if (Array.isArray(v)) for (const item of v) next.append(k, item)
      else if (v !== undefined && v !== '') next.set(k, v)
    }
    setSearch(next, { replace: true })
  }
  const pickSheet = (id: string) =>
    set({
      sheet: id === sheets[0]!.id ? undefined : id,
      // the plays sheet is the largest by far: seed the current season as a
      // removable chip so the first read is bounded, honestly and visibly
      where: id === 'plays' ? ['season:2026'] : [],
      q: undefined,
      order: undefined,
      desc: undefined,
      offset: undefined,
    })
  const toggleWhere = (column: string, value: string) => {
    const key = `${column}:${value}`
    const others = where.filter((w) => !w.startsWith(`${column}:`))
    set({ where: where.includes(key) ? others : [...others, key], offset: undefined })
  }
  const sortBy = (column: string) => {
    if (order === column || (!order && column === 'row_id')) set({ desc: desc ? undefined : '1', offset: undefined })
    else set({ order: column === 'row_id' ? undefined : column, desc: undefined, offset: undefined })
  }

  const data = res.data
  const rows: Row[] = data?.rows ?? []
  const filterCols = sheet.columns.filter((c) => (FILTERABLE as readonly string[]).includes(c.name))

  return (
    <div className="page page-explore">
      <div className="page-head">
        <h1>Explorer</h1>
        <p className="lede">
          {label}'s flat sheets, one table per grain: {sheet.description} Filters and the sort go to the API; the
          stats, the pivot and the copy work over the rows on this page.
        </p>
      </div>

      <div className="filters catalog-chips">
        <Chips label="Sheet" items={sheets.map((s) => ({ id: s.id, label: s.label }))} active={sheetId} onPick={pickSheet} />
        <Chips label="Rows" items={LIMITS.map((l) => ({ id: String(l), label: String(l) }))} active={String(limit)} onPick={(id) => set({ limit: id === '500' ? undefined : id, offset: undefined })} />
      </div>

      <div className="qbar">
        <label className="qwhere">
          <span>where</span>
          <input
            value={draft}
            spellCheck={false}
            placeholder="column op value and column op value  ·  ops: = != > < >= <="
            onChange={(e) => setDraft(e.target.value)}
            onBlur={() => draft.trim() !== (q ?? '') && set({ q: draft.trim() || undefined, offset: undefined })}
            onKeyDown={(e) => {
              if (e.key === 'Enter') set({ q: draft.trim() || undefined, offset: undefined })
            }}
          />
        </label>
        <span className="sheet-actions">
          <a className="chip" href={apiUrl(sport, sheetId, search, true)} download>
            Export CSV
          </a>
          <button
            type="button"
            className="chip"
            onClick={() => navigator.clipboard?.writeText(`${location.origin}${apiUrl(sport, sheetId, search, false)}`)}
          >
            Copy API call
          </button>
        </span>
      </div>
      {/* one compact select per filterable column: a chip per value buried the
          page under seven pill rows (18 weeks, 14 positions...) */}
      {filterCols.length > 0 && (
        <div className="filters">
          {filterCols.map((c) => {
            const values = distinct(rows, c.name, c.kind)
            const active = where.find((w) => w.startsWith(`${c.name}:`))?.slice(c.name.length + 1) ?? null
            if ((values.length === 0 || values.length > MAX_CHIPS) && !active) return null
            const options = active && !values.includes(active) ? [active, ...values] : values
            return (
              <label key={c.name} className="psel-wrap">
                {c.name}
                <select
                  className="psel"
                  value={active ?? ''}
                  onChange={(e) => {
                    // picking "any" re-toggles the active value off; with no
                    // active value there is nothing to clear
                    const v = e.target.value || active
                    if (v) toggleWhere(c.name, v)
                  }}
                >
                  <option value="">any</option>
                  {options.map((v) => (
                    <option key={v} value={v}>
                      {v}
                    </option>
                  ))}
                </select>
              </label>
            )
          })}
        </div>
      )}

      {res.error && (
        <section className="tile">
          <header className="tile-head">
            <h2>Nothing to show</h2>
          </header>
          <p className="hint">{res.error}</p>
        </section>
      )}

      {data && <Grid data={data} sheet={sheet} sortBy={sortBy} onPage={(o) => set({ offset: o ? String(o) : undefined })} />}

      <TileFrame title="How the Explorer is built" className="note-tile" query={[catalogQuery, data?.query].filter(Boolean).join('\n\n') || null}>
        <p>
          The catalog is each sheet's own DESCRIBE TABLE, typed into the kinds a grid needs; a sheet request is one
          select with equality filters on named columns, one sort column and a page, every column checked against the
          catalog before any SQL exists. The sheets are the flat app_explore tables, curated from the page marts so
          their columns are their own contract, which is also what a copy of APP into another store would carry.
        </p>
      </TileFrame>
    </div>
  )
}

function Grid({ data, sheet, sortBy, onPage }: { data: SheetPayload; sheet: SheetRef; sortBy: (c: string) => void; onPage: (offset: number) => void }) {
  const [picked, setPicked] = useState<string | null>(null)
  const [by, setBy] = useState<string | null>(null)
  const [agg, setAgg] = useState<Agg>('sum')
  const [copied, setCopied] = useState(false)
  const cols = data.columns.filter((c) => c.name !== 'row_id')
  const numeric = cols.filter((c) => isNumeric(c.kind))
  const textual = cols.filter((c) => !isNumeric(c.kind) && c.kind !== 'datetime')
  const statCol = picked && numeric.some((c) => c.name === picked) ? picked : defaultMeasure(cols, data.order)
  const s = useMemo(() => (statCol ? stats(data.rows, statCol) : null), [data.rows, statCol])
  const pv = useMemo(() => (by && statCol ? pivot(data.rows, by, statCol, agg) : null), [data.rows, by, statCol, agg])

  const copy = () => {
    const text = tsv(data.rows, data.columns)
    navigator.clipboard
      ?.writeText(text)
      .then(() => {
        setCopied(true)
        setTimeout(() => setCopied(false), 1500)
      })
      .catch(() => setCopied(false))
  }

  return (
    <>
      <div className="grid cols-explore">
        <TileFrame
          title="Column stats"
          meta={statCol ? `${statCol} over ${data.rows.length} rows` : 'no numeric column'}
          className="stats-tile"
          caption="Click a numeric column header to pick it. Over the rows on this page only."
        >
          {s && statCol ? (
            <div className="line-strip stats">
              <Stat v={fmt(s.count)} l="Values" />
              <Stat v={fmt(s.sum, Number.isInteger(s.sum) ? 0 : 1)} l="Sum" />
              <Stat v={fmt(s.avg, 2)} l="Average" />
              <Stat v={fmt(s.min, 1)} l="Min" />
              <Stat v={fmt(s.max, 1)} l="Max" />
              <Stat v={fmt(s.nulls)} l="Empty" />
            </div>
          ) : (
            <p className="hint">This sheet has no numeric column.</p>
          )}
        </TileFrame>
        <TileFrame title="Pivot" meta={pv ? `${pv.length} groups` : 'pick a group'} className="pivot-tile">
          <div className="filters chart-filters">
            <Chips label="Group by" items={[{ id: '', label: 'none' }, ...textual.map((c) => ({ id: c.name, label: c.name }))]} active={by ?? ''} onPick={(id) => setBy(id || null)} />
            <Chips label="Aggregate" items={AGGS.map((a) => ({ id: a, label: a }))} active={agg} onPick={(id) => setAgg(id as Agg)} />
          </div>
          {pv && statCol ? (
            <div className="trows pivot" style={{ '--cols': 'minmax(120px, 1.6fr) 60px minmax(90px, 1fr)' } as React.CSSProperties}>
              <div className="trow head">
                <span>{by}</span>
                <span className="n">rows</span>
                <span className="n">
                  {agg} {statCol}
                </span>
              </div>
              {pv.slice(0, 40).map((p) => (
                <div key={p.key} className="trow">
                  <span className="tm">
                    <b>{p.key}</b>
                  </span>
                  <span className="n">{p.rows}</span>
                  <span className="n">{fmt(p.value, agg === 'count' || Number.isInteger(p.value) ? 0 : 2)}</span>
                </div>
              ))}
              {pv.length > 40 && <p className="hint">{pv.length - 40} more groups not shown.</p>}
            </div>
          ) : (
            <p className="hint">Pick a column to group the page's rows by; the aggregate runs over the stats column.</p>
          )}
        </TileFrame>
      </div>

      <TileFrame
        title={sheet.label}
        meta={`${data.rows.length} rows${data.has_more ? ' of more' : ''} · ${cols.length} columns · sorted by ${data.order}${data.desc ? ' desc' : ''} · ${fmt(data.elapsed_ms, 0)}ms`}
        className="sheet-tile"
        caption={
          <span className="sheet-actions">
            <button type="button" className="chip" onClick={copy}>
              {copied ? 'Copied' : 'Copy as TSV'}
            </button>
            {data.offset > 0 && (
              <button type="button" className="chip" onClick={() => onPage(Math.max(0, data.offset - data.limit))}>
                Previous {data.limit}
              </button>
            )}
            {data.has_more && (
              <button type="button" className="chip" onClick={() => onPage(data.offset + data.limit)}>
                Next {data.limit}
              </button>
            )}
            <span className="hint">
              rows {data.offset + 1} to {data.offset + data.rows.length}
            </span>
          </span>
        }
      >
        <div className="sheet">
          <table>
            <thead>
              <tr>
                <th className="idx">#</th>
                {cols.map((c) => (
                  <th
                    key={c.name}
                    className={`${isNumeric(c.kind) ? 'num' : ''} ${data.order === c.name ? 'sorted' : ''} ${statCol === c.name ? 'picked' : ''}`}
                    onClick={() => {
                      if (isNumeric(c.kind)) setPicked(c.name)
                      sortBy(c.name)
                    }}
                    title={`${c.type}; click to sort${isNumeric(c.kind) ? ' and pick for stats' : ''}`}
                  >
                    {c.name}
                    {data.order === c.name ? (data.desc ? ' ↓' : ' ↑') : ''}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {data.rows.map((r, i) => (
                <tr key={String(r.row_id ?? i)}>
                  <td className="idx">{data.offset + i + 1}</td>
                  {cols.map((c) => (
                    <td key={c.name} className={`${isNumeric(c.kind) ? 'num' : ''} ${statCol === c.name ? 'picked' : ''}`}>
                      {formatCell(r[c.name] ?? null, c.kind)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
          {data.rows.length === 0 && <p className="hint">No rows match these filters.</p>}
        </div>
      </TileFrame>
    </>
  )
}

/** The API call the current view makes -- shareable, curl-able, exportable. */
function apiUrl(sport: string, sheetId: string, search: URLSearchParams, csv: boolean): string {
  const params = new URLSearchParams()
  for (const w of search.getAll('where')) params.append('where', w)
  for (const k of ['q', 'order', 'limit', 'offset'] as const) {
    const v = search.get(k)
    if (v) params.set(k, v)
  }
  if (search.get('desc') === '1') params.set('desc', 'true')
  if (csv) params.set('format', 'csv')
  const qs = params.toString()
  return `/api/${sport}/explore/${sheetId}${qs ? `?${qs}` : ''}`
}

function Stat({ v, l }: { v: string; l: string }) {
  return (
    <div className="stat">
      <span className="v">{v || '—'}</span>
      <span className="l">{l}</span>
    </div>
  )
}
