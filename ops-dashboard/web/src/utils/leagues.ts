/** Display names for the league headings.

    The API emits the registry stem (NFL, NCAAF, WNBA) plus the synthetic "dbt"
    league, and fixtures carry a different sport set from the live account, so the
    mapping is a client-side lookup with the code itself as the fallback: a sport
    added tomorrow reads as its stem rather than breaking the page. */
const LABELS: Record<string, string> = {
  NFL: 'NFL',
  NCAAF: 'College Football',
  WNBA: 'WNBA',
  DBT: 'dbt builds',
}

export function leagueLabel(sport: string): string {
  return LABELS[sport.toUpperCase()] ?? sport
}
