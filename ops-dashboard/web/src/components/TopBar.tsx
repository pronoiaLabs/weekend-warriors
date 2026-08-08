import type { ReactNode } from 'react'
import { NavLink } from 'react-router-dom'
import { useSportFilter } from '../hooks/useSportFilter.ts'

interface Props {
  meta?: ReactNode
}

function linkClass({ isActive }: { isActive: boolean }): string {
  return isActive ? 'active' : ''
}

export function TopBar({ meta }: Props) {
  const { search } = useSportFilter()

  return (
    <header className="topbar">
      <span className="brand">weekend-warriors ops</span>
      <nav>
        <NavLink to={{ pathname: '/', search }} end className={linkClass}>
          Overview
        </NavLink>
        <NavLink to={{ pathname: '/incidents', search }} className={linkClass}>
          Incidents
        </NavLink>
        <NavLink to={{ pathname: '/pipelines', search }} className={linkClass}>
          Pipelines
        </NavLink>
      </nav>
      <span className="meta">{meta}</span>
    </header>
  )
}
