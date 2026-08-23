import type { SlateCard, SlateLeague } from '../api/types.ts'

/** The day's score cards, sliced the way the dashboard filter chips speak. */
export const SLATE_VIEWS = ['all', 'ahead', 'failed', 'missed', 'missing', 'final'] as const
export type SlateView = (typeof SLATE_VIEWS)[number]

export const SLATE_KINDS = ['all', 'ingestion', 'dbt'] as const
export type SlateKind = (typeof SLATE_KINDS)[number]

export const VIEW_LABELS: Record<SlateView, string> = {
  all: 'All',
  ahead: 'Still ahead',
  failed: 'Failed',
  missed: 'No show',
  missing: 'Unrecorded',
  final: 'Final',
}

export const KIND_LABELS: Record<SlateKind, string> = {
  all: 'All jobs',
  ingestion: 'Ingestion',
  dbt: 'dbt',
}

export function isSlateView(value: string | null): value is SlateView {
  return value != null && (SLATE_VIEWS as readonly string[]).includes(value)
}

export function isSlateKind(value: string | null): value is SlateKind {
  return value != null && (SLATE_KINDS as readonly string[]).includes(value)
}

/** One card's place in the filter chips. Builds have no slot, so they are
    either Final or Failed; a run that never recorded itself is Unrecorded. */
export function cardView(card: SlateCard): Exclude<SlateView, 'all'> {
  if (card.kind === 'upcoming') return 'ahead'
  if (card.kind === 'missed') return 'missed'
  if (card.state === 'failure') return 'failed'
  if (card.state === 'missing') return 'missing'
  return 'final'
}

export function cardMatches(card: SlateCard, view: SlateView, kind: SlateKind): boolean {
  if (view !== 'all' && cardView(card) !== view) return false
  if (kind === 'ingestion' && card.kind === 'build') return false
  if (kind === 'dbt' && card.kind !== 'build') return false
  return true
}

export function viewCounts(leagues: SlateLeague[]): Record<SlateView, number> {
  const counts: Record<SlateView, number> = {
    all: 0,
    ahead: 0,
    failed: 0,
    missed: 0,
    missing: 0,
    final: 0,
  }
  for (const league of leagues) {
    for (const card of league.cards) {
      counts.all += 1
      counts[cardView(card)] += 1
    }
  }
  return counts
}

export function kindCounts(leagues: SlateLeague[]): Record<SlateKind, number> {
  const counts: Record<SlateKind, number> = { all: 0, ingestion: 0, dbt: 0 }
  for (const league of leagues) {
    for (const card of league.cards) {
      counts.all += 1
      if (card.kind === 'build') counts.dbt += 1
      else counts.ingestion += 1
    }
  }
  return counts
}

/** Drop empty leagues after the chips run, so a "Still ahead" pick does not
    leave a row of ingestion that already finished. */
export function filterLeagues(leagues: SlateLeague[], view: SlateView, kind: SlateKind): SlateLeague[] {
  return leagues
    .map((league) => ({
      ...league,
      cards: league.cards.filter((card) => cardMatches(card, view, kind)),
    }))
    .filter((league) => league.cards.length > 0)
}
