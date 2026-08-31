import type { LeadersRow, PlayerWeekRow } from '../api/sports/types.ts'

/** What each position group shows: the leaderboard's sortable columns, the
    player page's headline stats, the stats its chart offers and the game
    log's columns. One place, so the finder, the player page and the roster
    agree on what matters for a QB versus a WR.

    The finder's thesis is usage: target share and snap % ride on every group
    that has them, PPR is the fantasy currency (nflverse, the best-covered
    feed), and the FanDuel/DraftKings columns stay in the marts for the
    Explorer without cluttering the finder. */

export type Group = 'QB' | 'RB' | 'WR' | 'TE' | 'OTHER'

export function groupOf(position: string | null | undefined): Group {
  if (position === 'QB' || position === 'RB' || position === 'WR' || position === 'TE') return position
  return 'OTHER'
}

export const POSITIONS: { id: string; label: string }[] = [
  { id: 'QB', label: 'QB' },
  { id: 'RB', label: 'RB' },
  { id: 'WR', label: 'WR' },
  { id: 'TE', label: 'TE' },
]

export interface Col {
  key: keyof LeadersRow
  label: string
  digits?: number
  /** the mart's rank column when this column is sortable */
  rank?: keyof LeadersRow
  pct?: boolean
}

const USAGE: Col[] = [
  { key: 'target_share', label: 'Tgt %', pct: true, digits: 1, rank: 'rank_target_share' },
  { key: 'snap_share', label: 'Snap %', pct: true, digits: 0, rank: 'rank_snap_share' },
  { key: 'ppr_points', label: 'PPR', digits: 1, rank: 'rank_ppr_points' },
]

export const LEADER_COLS: Record<Group, Col[]> = {
  QB: [
    { key: 'passing_completions', label: 'Cmp' },
    { key: 'completion_pct', label: 'Cmp%', pct: true, digits: 1 },
    { key: 'passing_yards', label: 'Pass yds', rank: 'rank_passing_yards' },
    { key: 'passing_touchdowns', label: 'Pass TD', rank: 'rank_passing_touchdowns' },
    { key: 'passing_interceptions', label: 'INT' },
    { key: 'rushing_yards', label: 'Rush yds', rank: 'rank_rushing_yards' },
    // a QB has no target share; snap and PPR still tell the usage story
    { key: 'snap_share', label: 'Snap %', pct: true, digits: 0, rank: 'rank_snap_share' },
    { key: 'ppr_points', label: 'PPR', digits: 1, rank: 'rank_ppr_points' },
  ],
  RB: [
    { key: 'rushing_attempts', label: 'Att' },
    { key: 'rushing_yards', label: 'Rush yds', rank: 'rank_rushing_yards' },
    { key: 'receptions', label: 'Rec', rank: 'rank_receptions' },
    { key: 'receiving_yards', label: 'Rec yds', rank: 'rank_receiving_yards' },
    { key: 'scoring_touchdowns', label: 'TD', rank: 'rank_scoring_touchdowns' },
    ...USAGE,
  ],
  WR: [
    { key: 'receptions', label: 'Rec', rank: 'rank_receptions' },
    { key: 'receiving_yards', label: 'Yds', rank: 'rank_receiving_yards' },
    { key: 'receiving_touchdowns', label: 'TD', rank: 'rank_receiving_touchdowns' },
    { key: 'catch_rate', label: 'Catch%', pct: true, digits: 0 },
    ...USAGE,
  ],
  TE: [
    { key: 'receptions', label: 'Rec', rank: 'rank_receptions' },
    { key: 'receiving_yards', label: 'Yds', rank: 'rank_receiving_yards' },
    { key: 'receiving_touchdowns', label: 'TD', rank: 'rank_receiving_touchdowns' },
    { key: 'catch_rate', label: 'Catch%', pct: true, digits: 0 },
    ...USAGE,
  ],
  OTHER: [
    { key: 'rushing_yards', label: 'Rush yds', rank: 'rank_rushing_yards' },
    { key: 'receiving_yards', label: 'Rec yds', rank: 'rank_receiving_yards' },
    { key: 'scrimmage_yards', label: 'Scrim yds', rank: 'rank_scrimmage_yards' },
    { key: 'scoring_touchdowns', label: 'TD', rank: 'rank_scoring_touchdowns' },
    ...USAGE,
  ],
}

/** The default sort per group: usage first where the position has it (the
    finder's thesis), the yardage rank for QBs. */
export const DEFAULT_SORT: Record<Group, keyof LeadersRow> = {
  QB: 'rank_passing_yards',
  RB: 'rank_target_share',
  WR: 'rank_target_share',
  TE: 'rank_target_share',
  OTHER: 'rank_ppr_points',
}

/** The tie-break rank behind the sort: with no vendor coverage (preseason)
    every usage rank ties at 1, and this keeps the table ordered by the
    position's yardage instead of alphabetically. */
export const FALLBACK_SORT: Record<Group, keyof LeadersRow> = {
  QB: 'rank_passing_yards',
  RB: 'rank_rushing_yards',
  WR: 'rank_receiving_yards',
  TE: 'rank_receiving_yards',
  OTHER: 'rank_scrimmage_yards',
}

export interface ChartStat {
  key: string
  label: string
  pct?: boolean
}

/** The chart's stat picker: four per group (the wireframe's set), every key a
    stat_key in app_player_week_stats so prior-season columns ride along. */
export const CHART_STATS: Record<Group, ChartStat[]> = {
  QB: [
    { key: 'passing_yards', label: 'Pass yards' },
    { key: 'passing_touchdowns', label: 'Pass TDs' },
    { key: 'passing_attempts', label: 'Attempts' },
    { key: 'ppr_points', label: 'PPR' },
  ],
  RB: [
    { key: 'rushing_yards', label: 'Rush yards' },
    { key: 'touches', label: 'Touches' },
    { key: 'target_share', label: 'Target share', pct: true },
    { key: 'ppr_points', label: 'PPR' },
  ],
  WR: [
    { key: 'receiving_yards', label: 'Yards' },
    { key: 'receiving_targets', label: 'Targets' },
    { key: 'target_share', label: 'Target share', pct: true },
    { key: 'ppr_points', label: 'PPR' },
  ],
  TE: [
    { key: 'receiving_yards', label: 'Yards' },
    { key: 'receiving_targets', label: 'Targets' },
    { key: 'target_share', label: 'Target share', pct: true },
    { key: 'ppr_points', label: 'PPR' },
  ],
  OTHER: [
    { key: 'scrimmage_yards', label: 'Scrimmage yards' },
    { key: 'touches', label: 'Touches' },
    { key: 'scoring_touchdowns', label: 'Touchdowns' },
    { key: 'ppr_points', label: 'PPR' },
  ],
}

export interface WeekCol {
  key: keyof PlayerWeekRow
  label: string
  digits?: number
  pct?: boolean
  /** signed with a pos/neg tone (EPA) */
  signed?: boolean
}

const LOG_TAIL: WeekCol[] = [
  { key: 'snap_pct', label: 'Snap %', pct: true, digits: 0 },
  { key: 'ppr_points', label: 'PPR', digits: 1 },
]

export const WEEK_COLS: Record<Group, WeekCol[]> = {
  QB: [
    { key: 'passing_completions', label: 'Cmp' },
    { key: 'passing_attempts', label: 'Att' },
    { key: 'passing_yards', label: 'Yds' },
    { key: 'passing_touchdowns', label: 'TD' },
    { key: 'passing_interceptions', label: 'INT' },
    { key: 'rushing_yards', label: 'Rush' },
    { key: 'passing_epa', label: 'EPA', digits: 1, signed: true },
    ...LOG_TAIL,
  ],
  RB: [
    { key: 'rushing_attempts', label: 'Att' },
    { key: 'rushing_yards', label: 'Yds' },
    { key: 'rushing_touchdowns', label: 'TD' },
    { key: 'receiving_targets', label: 'Tgt' },
    { key: 'receptions', label: 'Rec' },
    { key: 'receiving_yards', label: 'Rec yds' },
    { key: 'rushing_epa', label: 'EPA', digits: 1, signed: true },
    ...LOG_TAIL,
  ],
  WR: [
    { key: 'receiving_targets', label: 'Tgt' },
    { key: 'receptions', label: 'Rec' },
    { key: 'receiving_yards', label: 'Yds' },
    { key: 'receiving_touchdowns', label: 'TD' },
    { key: 'target_share', label: 'Tgt %', pct: true, digits: 0 },
    { key: 'air_yards_share', label: 'Air %', pct: true, digits: 0 },
    { key: 'receiving_epa', label: 'EPA', digits: 1, signed: true },
    ...LOG_TAIL,
  ],
  TE: [
    { key: 'receiving_targets', label: 'Tgt' },
    { key: 'receptions', label: 'Rec' },
    { key: 'receiving_yards', label: 'Yds' },
    { key: 'receiving_touchdowns', label: 'TD' },
    { key: 'target_share', label: 'Tgt %', pct: true, digits: 0 },
    { key: 'air_yards_share', label: 'Air %', pct: true, digits: 0 },
    { key: 'receiving_epa', label: 'EPA', digits: 1, signed: true },
    ...LOG_TAIL,
  ],
  OTHER: [
    { key: 'touches', label: 'Touches' },
    { key: 'scrimmage_yards', label: 'Scrim yds' },
    { key: 'scoring_touchdowns', label: 'TD' },
    ...LOG_TAIL,
  ],
}

export function statLabel(group: Group, key: string): string {
  return CHART_STATS[group].find((s) => s.key === key)?.label ?? key.replace(/_/g, ' ')
}
