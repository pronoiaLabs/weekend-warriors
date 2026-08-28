import { useState } from 'react'

/** Player headshot with the initials always painted underneath (the wireframe's
    pattern): nflverse headshot first, the Sleeper CDN by player id when that
    404s, and the initials show through whenever no image loads. */
export default function Avatar({
  name,
  headshotUrl,
  sleeperPlayerId,
  size,
}: {
  name: string
  headshotUrl?: string | null
  sleeperPlayerId?: string | null
  size?: 'sm' | 'lg' | 'xl'
}) {
  // 0 = primary, 1 = sleeper fallback, 2 = initials only
  const [attempt, setAttempt] = useState(0)
  const sources = [
    headshotUrl ?? undefined,
    sleeperPlayerId ? `https://sleepercdn.com/content/nfl/players/${sleeperPlayerId}.jpg` : undefined,
  ]
  const src = sources[attempt] ?? sources[attempt + 1]
  const initials = name
    .split(/[\s'-]+/)
    .filter(Boolean)
    .map((w) => w[0])
    .slice(0, 2)
    .join('')
    .toUpperCase()
  return (
    <span className={`avatar ${size ?? ''}`}>
      {attempt < 2 && src && <img src={src} alt="" loading="lazy" onError={() => setAttempt(attempt + 1)} />}
      {initials}
    </span>
  )
}
