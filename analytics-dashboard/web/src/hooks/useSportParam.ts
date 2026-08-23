import { useParams } from 'react-router-dom'

/** The sport comes from the path (/nfl/...). Lowercased here so links and API
    calls agree; the API is case-insensitive on the segment anyway. */
export function useSportParam(): string {
  const { sport } = useParams<{ sport: string }>()
  return (sport ?? 'nfl').toLowerCase()
}
