import type { Block, BoardWindow } from '../api/types.ts'

/** Real runs are 50 to 130 seconds against a window most of a day wide, which is
    under two pixels at true scale. Block width is duration at a fixed
    exaggeration; only the left edge is honest about the clock. */
const PX_PER_SECOND = 0.31
const MIN_RUN_PX = 26
const MIN_RUN_PX_SM = 20
/** A missed or upcoming slot has no duration, so it gets a nominal width wide
    enough to hold its label. */
const SLOT_PX = 34
const SLOT_PX_SM = 28

/** Share of the window a block is assumed to occupy when dodging overlaps. The
    stagger works in time, not pixels, so it needs a footprint for a 90 s run. */
const MIN_FOOTPRINT = 0.035

const TICK_STEPS_MIN = [15, 30, 60, 120, 180, 240, 360, 720]
const MAX_TICKS = 9

export interface Scale {
  startMs: number
  endMs: number
  spanMs: number
}

export function makeScale(window: BoardWindow): Scale {
  const startMs = Date.parse(window.start)
  const endMs = Date.parse(window.end)
  return { startMs, endMs, spanMs: Math.max(endMs - startMs, 1) }
}

/** Position of an instant as a percentage of the window, clamped to the track. */
export function positionPct(scale: Scale, iso: string): number {
  const offset = (Date.parse(iso) - scale.startMs) / scale.spanMs
  return Math.min(Math.max(offset, 0), 1) * 100
}

export function withinWindow(scale: Scale, iso: string): boolean {
  const at = Date.parse(iso)
  return at >= scale.startMs && at <= scale.endMs
}

export function blockWidthPx(block: Block, compact = false): number {
  if (block.kind !== 'run') {
    return compact ? SLOT_PX_SM : SLOT_PX
  }
  const floor = compact ? MIN_RUN_PX_SM : MIN_RUN_PX
  return Math.max(floor, Math.round((block.duration_s ?? 0) * PX_PER_SECOND))
}

/** Tick instants for the axis, aligned to whole UTC minutes so labels land on
    readable times rather than on the window's padded edges. */
export function axisTicks(scale: Scale): number[] {
  const spanMin = scale.spanMs / 60000
  const step = TICK_STEPS_MIN.find((minutes) => spanMin / minutes <= MAX_TICKS) ?? 1440
  const stepMs = step * 60000
  const ticks: number[] = []
  for (let at = Math.ceil(scale.startMs / stepMs) * stepMs; at <= scale.endMs; at += stepMs) {
    ticks.push(at)
  }
  return ticks
}

export function sortByTime(blocks: Block[]): Block[] {
  return [...blocks].sort((a, b) => Date.parse(a.at) - Date.parse(b.at))
}

/** Row index (0 or 1) per block so a rolled-up sport lane can dodge overlaps.
    Blocks must already be sorted by time. */
export function staggerRows(blocks: Block[], scale: Scale): number[] {
  const rowFreeAt = [-Infinity, -Infinity]
  return blocks.map((block) => {
    const startsAt = Date.parse(block.at)
    const footprint = Math.max(scale.spanMs * MIN_FOOTPRINT, (block.duration_s ?? 0) * 1000)
    const row = startsAt >= rowFreeAt[0] ? 0 : 1
    rowFreeAt[row] = startsAt + footprint
    return row
  })
}
