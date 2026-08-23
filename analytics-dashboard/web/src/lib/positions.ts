import type { LeadersRow, PlayerWeekRow } from '../api/sports/types.ts'

/** What each position group shows: the leaderboard's sortable columns, the
    player page's headline stats, the stats its chart offers and the week
    table's columns. One place, so the leaderboard, the player page and the
    roster agree on what matters for a QB versus a WR. */

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

const FANTASY: Col[] = [
  { key: 'fanduel_points', label: 'FD pts', digits: 1, rank: 'rank_fanduel_points' },
  { key: 'fanduel_points_per_game', label: 'FD /g', digits: 2, rank: 'rank_fanduel_points_per_game' },
  { key: 'draftkings_points', label: 'DK pts', digits: 1, rank: 'rank_draftkings_points' },
]

export const LEADER_COLS: Record<Group, Col[]> = {
  QB: [
    { key: 'passing_completions', label: 'Cmp' },
    { key: 'passing_attempts', label: 'Att' },
    { key: 'completion_pct', label: 'Cmp%', pct: true },
    { key: 'passing_yards', label: 'Pass yds', rank: 'rank_passing_yards' },
    { key: 'passing_touchdowns', label: 'Pass TD', rank: 'rank_passing_touchdowns' },
    { key: 'passing_interceptions', label: 'INT' },
    { key: 'yards_per_pass_attempt', label: 'Y/A', digits: 1 },
    { key: 'rushing_yards', label: 'Rush yds', rank: 'rank_rushing_yards' },
    { key: 'rushing_touchdowns', label: 'Rush TD' },
    ...FANTASY,
  ],
  RB: [
    { key: 'rushing_attempts', label: 'Att' },
    { key: 'rushing_yards', label: 'Rush yds', rank: 'rank_rushing_yards' },
    { key: 'yards_per_rush_attempt', label: 'Y/A', digits: 1 },
    { key: 'rushing_touchdowns', label: 'Rush TD', rank: 'rank_rushing_touchdowns' },
    { key: 'receptions', label: 'Rec', rank: 'rank_receptions' },
    { key: 'receiving_yards', label: 'Rec yds', rank: 'rank_receiving_yards' },
    { key: 'scrimmage_yards', label: 'Scrim yds', rank: 'rank_scrimmage_yards' },
    { key: 'scoring_touchdowns', label: 'TD', rank: 'rank_scoring_touchdowns' },
    ...FANTASY,
  ],
  WR: [
    { key: 'receiving_targets', label: 'Tgt' },
    { key: 'receptions', label: 'Rec', rank: 'rank_receptions' },
    { key: 'receiving_yards', label: 'Rec yds', rank: 'rank_receiving_yards' },
    { key: 'yards_per_reception', label: 'Y/R', digits: 1 },
    { key: 'receiving_touchdowns', label: 'Rec TD', rank: 'rank_receiving_touchdowns' },
    { key: 'catch_rate', label: 'Catch%', pct: true },
    { key: 'rushing_yards', label: 'Rush yds' },
    { key: 'scoring_touchdowns', label: 'TD', rank: 'rank_scoring_touchdowns' },
    ...FANTASY,
  ],
  TE: [
    { key: 'receiving_targets', label: 'Tgt' },
    { key: 'receptions', label: 'Rec', rank: 'rank_receptions' },
    { key: 'receiving_yards', label: 'Rec yds', rank: 'rank_receiving_yards' },
    { key: 'yards_per_reception', label: 'Y/R', digits: 1 },
    { key: 'receiving_touchdowns', label: 'Rec TD', rank: 'rank_receiving_touchdowns' },
    { key: 'catch_rate', label: 'Catch%', pct: true },
    { key: 'scoring_touchdowns', label: 'TD', rank: 'rank_scoring_touchdowns' },
    ...FANTASY,
  ],
  OTHER: [
    { key: 'rushing_yards', label: 'Rush yds', rank: 'rank_rushing_yards' },
    { key: 'receiving_yards', label: 'Rec yds', rank: 'rank_receiving_yards' },
    { key: 'scrimmage_yards', label: 'Scrim yds', rank: 'rank_scrimmage_yards' },
    { key: 'scoring_touchdowns', label: 'TD', rank: 'rank_scoring_touchdowns' },
    ...FANTASY,
  ],
}

/** The default sort per group: the column the position is judged by. */
export const DEFAULT_SORT: Record<Group, keyof LeadersRow> = {
  QB: 'rank_passing_yards',
  RB: 'rank_rushing_yards',
  WR: 'rank_receiving_yards',
  TE: 'rank_receiving_yards',
  OTHER: 'rank_fanduel_points',
}

export interface ChartStat {
  key: string
  label: string
}

export const CHART_STATS: Record<Group, ChartStat[]> = {
  QB: [
    { key: 'passing_yards', label: 'Passing yards' },
    { key: 'passing_touchdowns', label: 'Passing TDs' },
    { key: 'passing_attempts', label: 'Attempts' },
    { key: 'passing_interceptions', label: 'Interceptions' },
    { key: 'rushing_yards', label: 'Rushing yards' },
    { key: 'fanduel_points', label: 'FanDuel points' },
    { key: 'draftkings_points', label: 'DraftKings points' },
  ],
  RB: [
    { key: 'rushing_yards', label: 'Rushing yards' },
    { key: 'rushing_attempts', label: 'Carries' },
    { key: 'receiving_yards', label: 'Receiving yards' },
    { key: 'receptions', label: 'Receptions' },
    { key: 'scrimmage_yards', label: 'Scrimmage yards' },
    { key: 'touches', label: 'Touches' },
    { key: 'scoring_touchdowns', label: 'Touchdowns' },
    { key: 'fanduel_points', label: 'FanDuel points' },
    { key: 'draftkings_points', label: 'DraftKings points' },
  ],
  WR: [
    { key: 'receiving_yards', label: 'Receiving yards' },
    { key: 'receptions', label: 'Receptions' },
    { key: 'receiving_targets', label: 'Targets' },
    { key: 'receiving_touchdowns', label: 'Receiving TDs' },
    { key: 'rushing_yards', label: 'Rushing yards' },
    { key: 'fanduel_points', label: 'FanDuel points' },
    { key: 'draftkings_points', label: 'DraftKings points' },
  ],
  TE: [
    { key: 'receiving_yards', label: 'Receiving yards' },
    { key: 'receptions', label: 'Receptions' },
    { key: 'receiving_targets', label: 'Targets' },
    { key: 'receiving_touchdowns', label: 'Receiving TDs' },
    { key: 'fanduel_points', label: 'FanDuel points' },
    { key: 'draftkings_points', label: 'DraftKings points' },
  ],
  OTHER: [
    { key: 'scrimmage_yards', label: 'Scrimmage yards' },
    { key: 'touches', label: 'Touches' },
    { key: 'scoring_touchdowns', label: 'Touchdowns' },
    { key: 'fanduel_points', label: 'FanDuel points' },
  ],
}

export interface WeekCol {
  key: keyof PlayerWeekRow
  label: string
  digits?: number
}

export const WEEK_COLS: Record<Group, WeekCol[]> = {
  QB: [
    { key: 'passing_completions', label: 'Cmp' },
    { key: 'passing_attempts', label: 'Att' },
    { key: 'passing_yards', label: 'Pass yds' },
    { key: 'passing_touchdowns', label: 'TD' },
    { key: 'passing_interceptions', label: 'INT' },
    { key: 'qb_rating', label: 'Rtg', digits: 1 },
    { key: 'times_sacked', label: 'Sck' },
    { key: 'rushing_yards', label: 'Rush yds' },
    { key: 'fanduel_points', label: 'FD', digits: 1 },
    { key: 'draftkings_points', label: 'DK', digits: 1 },
  ],
  RB: [
    { key: 'rushing_attempts', label: 'Att' },
    { key: 'rushing_yards', label: 'Rush yds' },
    { key: 'rushing_touchdowns', label: 'Rush TD' },
    { key: 'receiving_targets', label: 'Tgt' },
    { key: 'receptions', label: 'Rec' },
    { key: 'receiving_yards', label: 'Rec yds' },
    { key: 'receiving_touchdowns', label: 'Rec TD' },
    { key: 'touches', label: 'Touches' },
    { key: 'fanduel_points', label: 'FD', digits: 1 },
    { key: 'draftkings_points', label: 'DK', digits: 1 },
  ],
  WR: [
    { key: 'receiving_targets', label: 'Tgt' },
    { key: 'receptions', label: 'Rec' },
    { key: 'receiving_yards', label: 'Rec yds' },
    { key: 'receiving_touchdowns', label: 'Rec TD' },
    { key: 'long_reception', label: 'Long' },
    { key: 'rushing_attempts', label: 'Car' },
    { key: 'rushing_yards', label: 'Rush yds' },
    { key: 'fanduel_points', label: 'FD', digits: 1 },
    { key: 'draftkings_points', label: 'DK', digits: 1 },
  ],
  TE: [
    { key: 'receiving_targets', label: 'Tgt' },
    { key: 'receptions', label: 'Rec' },
    { key: 'receiving_yards', label: 'Rec yds' },
    { key: 'receiving_touchdowns', label: 'Rec TD' },
    { key: 'long_reception', label: 'Long' },
    { key: 'fanduel_points', label: 'FD', digits: 1 },
    { key: 'draftkings_points', label: 'DK', digits: 1 },
  ],
  OTHER: [
    { key: 'touches', label: 'Touches' },
    { key: 'scrimmage_yards', label: 'Scrim yds' },
    { key: 'scoring_touchdowns', label: 'TD' },
    { key: 'fanduel_points', label: 'FD', digits: 1 },
    { key: 'draftkings_points', label: 'DK', digits: 1 },
  ],
}

export function statLabel(group: Group, key: string): string {
  return CHART_STATS[group].find((s) => s.key === key)?.label ?? key.replace(/_/g, ' ')
}
