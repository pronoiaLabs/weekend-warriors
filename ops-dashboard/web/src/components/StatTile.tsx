import type { To } from 'react-router-dom'
import { Link } from 'react-router-dom'

interface Props {
  value: number | string
  label: string
  alert?: boolean
  to?: To
}

export function StatTile({ value, label, alert, to }: Props) {
  return (
    <div className={alert ? 'stat alert' : 'stat'}>
      <div className="n">{to ? <Link to={to}>{value}</Link> : value}</div>
      <div className="l">{label}</div>
    </div>
  )
}
