import type { BrandingRow } from '../../api/sports/types.ts'

/** Team mark from the branding map (useBranding). Falls back to the label as
    text when the team has no branding row or the image fails. */
export default function TeamLogo({
  teamKey,
  label,
  branding,
  size,
}: {
  teamKey: string | null | undefined
  label?: string | null
  branding: Map<string, BrandingRow>
  size?: 'sm' | 'lg' | 'xl'
}) {
  const row = teamKey ? branding.get(teamKey) : undefined
  const src = row?.logo_squared_url ?? row?.logo_url
  if (!src) return label ? <span className="tlogo-fallback">{label}</span> : null
  return (
    <img
      className={`tlogo ${size ?? ''}`}
      src={src}
      alt={row?.team_label ?? label ?? ''}
      loading="lazy"
      onError={(e) => {
        e.currentTarget.style.display = 'none'
      }}
    />
  )
}
