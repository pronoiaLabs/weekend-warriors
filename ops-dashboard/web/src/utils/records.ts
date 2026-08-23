/** The standings columns shared by the rail's records panel and the pipelines
    page: a pct with a placeholder for a window that never decided, and the
    streak's colour by its first letter. */

export function pctText(value: number | null | undefined): string {
  return value == null ? '·' : value.toFixed(3)
}

export function streakClass(streak: string | null | undefined): string {
  if (!streak) return 'strk'
  return streak.startsWith('W') ? 'strk w' : 'strk l'
}
